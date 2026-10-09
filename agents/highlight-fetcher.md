---
name: highlight-fetcher
description: >
  Fetches the user's Readwise highlights updated since a given timestamp via
  the `readwise` MCP server and writes ONE file per source document to
  {output_path}/{YYYY-MM-DD} {slug-title}.md. Idempotent — keyed on the
  `highlight_ids` frontmatter list, so highlights already captured are never
  re-written and existing files are never touched. Body is the source URL
  first, then the highlights in reading order, then `## Context`.
subagent_type: general-purpose
---

# Agent: Highlight Fetcher

**Role:** Pull the user's Readwise highlights updated since `{since}`, group
them by source document, and persist one file per source to
`{output_path}/{YYYY-MM-DD} {slug-title}.md`. Use the `readwise` MCP server
for every Readwise call — never `curl`, `wget`, or library clients. The MCP
server is the only client configured with the user's Readwise auth.

**Inputs (passed by `/pull-highlights`):**

- `since` — RFC 3339 UTC, e.g. `2026-10-07T00:00:00Z`, OR `null` for full history
- `output_path` — absolute directory (must exist or be creatable)
- `vault_root` — absolute path
- `run_date` — `YYYY-MM-DD`, local date of the run (used in filename + `created`)
- `naming_pattern` — e.g. `{date} {slug-title}`

---

## Bootstrap

1. Create `{output_path}` if absent:
   ```bash
   mkdir -p {output_path}
   ```

2. Reachability is proven by step 2's first call. If it fails with an auth or
   connection error, abort with:
   `readwise MCP unreachable — re-authenticate the readwise server and retry`.

---

## Process

### 1. Build the existing-ID index (idempotency)

Single sweep at run start. Read the `highlight_ids:` frontmatter line of every
`.md` in `{output_path}` (use `find -L`, never `grep -R` — the folder may sit
behind a symlink) and collect every ID into one set.

The join key is the **highlight ID**, not the source (`readwise_book_id`). A
source pulled last week can gain new highlights today; those land in a new
dated file while last week's file — possibly already ingested and `done` —
stays untouched.

### 2. List highlights, paginated

```
mcp__readwise__readwise_list_highlights(
  updated_gt: "{since}",          # omit entirely when since is null (full history)
  page_size: 1000,
  page: {n},                      # 1, 2, ... until the response's `next` is null
  response_fields: ["text", "note", "location", "highlighted_at", "updated",
                    "book_id", "book_title", "book_author", "book_category",
                    "book_source_url", "book_highlights_url"]
)
```

> **Filter on `updated_gt`, never `highlighted_at_gt`.** Readwise stamps
> highlights at *sync* time — a whole X thread saved from Reader arrives as
> 9 highlights within 4 seconds — and a Kindle sync can deliver highlights
> whose `highlighted_at` is weeks old. A `highlighted_at` window silently
> drops those. `updated` is the incremental-sync cursor.

> **Large results overflow the tool output.** A full-history pull (~180
> highlights) returned ~140 KB and was spilled to a file. When that happens,
> parse the saved JSON file with `jq`/`python3 -I` rather than reading it
> into context.

### 3. Filter and group

- Drop every highlight whose `id` is in the step-1 index → count as `unchanged`.
- Drop the **Gmail forwarding confirmation** document (title starts with
  `✅ Gmail Forwarding Confirmed`, author `Gmail Team`): its only "highlight"
  is a Gmail verification URL carrying a token. Not reading material, and the
  token does not belong in the vault. Count as `skipped`.
- Group the rest by `book_id`. Within a group, sort by `location` ascending
  (reading order), tie-break on `highlighted_at`.

### 4. Clean the source URL

From `book_source_url`:

- Remove query params named `rw_*` (Readwise tracking), `utm_*`, and `s`
  (X share param). Drop the `?` if nothing is left.
- For `twitter.com` / `x.com`, strip the trailing `/` from the path.
- `mailto:reader-forwarded-email/...` = a newsletter forwarded into Reader.
  There is **no public URL**: set `source_url: ""` and use the
  `book_highlights_url` (readwise.io/bookreview/…) in the `Source:` line.

### 5. Slugify title + filename

Same algorithm as `meeting-fetcher` step 5: lowercase → **transliterate
accents to ASCII before stripping** (`é → e`, `ñ → n` — never delete them) →
whitespace to `-` → strip outside `[a-z0-9-]` → collapse/trim hyphens → cap
~60 chars on a word boundary → fall back to `book_id` if empty.

Filename: `{run_date} {slug-title}.md`. On collision with an existing file or
another source in this run, append `-2`, `-3`, … to the slug.

### 6. Write file (new only)

Frontmatter — strict shape:

```yaml
---
type: raw
status: inbox
source: readwise
created: {run_date}
title: "{book_title, verbatim, double-quoted}"
author: "{book_author}"
category: {book_category}            # books | articles | tweets | podcasts | supplementals
source_url: "{cleaned url, or empty}"
readwise_book_id: {book_id}
highlight_ids: [{id1}, {id2}, ...]   # this file's highlights only, reading order
tags: [raw, inbox, readwise, highlight]
---
```

Body — **source URL first, then the highlights**:

```markdown
# {book_title}

Source: {cleaned url}
<!-- or, for forwarded email: Source: forwarded email (no public URL) — {book_highlights_url} -->

## Highlights

> {highlight text, every line prefixed with "> ", blank lines as ">"}

**Note:** {the user's note, verbatim — only when non-empty}

> {next highlight}

## Context
- Author: {book_author}
- Category: {book_category}
- Highlighted: {earliest highlighted_at date}[ → {latest}]
- Readwise: {book_highlights_url}

## Notes
```

- Each highlight is its own blockquote separated by a blank line, so they
  render as distinct quotes.
- Keep note text verbatim. Some notes are Reader's built-in dictionary
  lookups (e.g. `The (article)` + a definition) rather than user annotations;
  they are still the user's data — do not filter or rewrite them here.
- `## Notes` is deliberately empty for the user or `expand-raw-ideas`.

**Write path:** `obsidian create path="{relative path}" content="$BODY" </dev/null`
with the full note, frontmatter included (`create` does not prepend a
newline, so `---` stays at byte 0). In a loop, build the list as a zsh array
(`NAMES=("${(@f)$(cat list)}")`) — never rely on unquoted word splitting.

### 7. Verify (in a separate invocation)

Obsidian writes are asynchronous; never verify in the same shell command
that wrote. In a later call, confirm per file: it exists, line 1 is `---`,
and no `{name} 1.md` fork exists. Then confirm the sum of `highlight_ids`
across files written equals the number of highlights you intended to write.
A file that is missing after verification counts as `error`.

### 8. Counts

- `new_files` — source files written and verified.
- `new_highlights` — highlights inside them.
- `unchanged` — highlights skipped because their ID was already indexed.
- `skipped` — highlights deliberately dropped (Gmail confirmation).
- `error` — list/write/parse failure.

---

## Output

```
highlight-fetcher complete
window:          {since | full history}
new_files:       {N}
new_highlights:  {N}
unchanged:       {N}
skipped:         {N}
errors:          [list with book_id + reason]
files_written:   [absolute paths, new only]
```

---

## Resilience

- Readwise MCP unreachable / auth failure → abort, print re-auth instruction.
- Zero highlights in the window → `new_files: 0`, exit cleanly. Normal case.
- Per-source write/parse error → log, count, continue with the next source.

---

## Anti-patterns

- Do NOT call Readwise HTTP endpoints directly. Use the `readwise` MCP server.
- Do NOT key idempotency on filename or `book_id`. The `highlight_ids` set is
  the only join key.
- Do NOT append new highlights to an existing source file — it may already be
  ingested (`status: done`) or user-edited. New highlights → new dated file.
- Do NOT write one file per highlight. `/ingest` expands every raw file into a
  wiki note; per-highlight files turn one saved thread into 9 near-duplicates.
- Do NOT delete files for upstream-deleted highlights — non-destructive archive.
- Do NOT report success without the step-7 verification.
