---
name: wiki-manager:pull-highlights
description: >
  Fetch your Readwise highlights into raw/highlights/ for the ingest pipeline.
  Defaults to highlights updated in the past 2 days; `--all` pulls full history.
  One file per source document (source URL first, then the highlights).
  Idempotent: keyed on `highlight_ids` frontmatter, so re-runs never duplicate
  a highlight and never touch existing files.
---

# Pull Highlights

Pull your Readwise highlights via the `readwise` MCP server and persist them
as one raw file per source document. Output path comes from `readwise.yaml`:

- sources: `{vault_root}/{path}{YYYY-MM-DD} {slug-title}.md`

Files land with `status: inbox`, so `/ingest` expands each source into a wiki
note — the highlights are the idea, the source URL is context.

**Readwise API access tool: the `readwise` MCP server.** Never substitute
`curl` or library clients. If the MCP is absent or auth fails, abort with a
clear error rather than partial-fetching.

---

## Args

- `--days N` — lookback window in days. Overrides `readwise.window_days`.
- `--since YYYY-MM-DD` — explicit start date (overrides `--days`).
- `--all` — full history (no `updated_gt` filter). Use for the first pull.
  Safe to re-run: already-captured highlight IDs are skipped.

---

## Process

### 1. Resolve config

Invoke the `manifest-resolver` skill to load `vault-paths` and `readwise`.
Capture:

- `vault_root` — absolute path (from vault-paths)
- `path` — relative output dir (from readwise), trailing slash
- `window_days`
- `naming.pattern` and `naming.date_format`

### 2. Compute the `since` boundary

`since` = `--all` (→ `null`) > `--since` > `--days` > `readwise.window_days`.

Convert a date to RFC 3339 UTC at midnight: `YYYY-MM-DDT00:00:00Z`.

### 3. Dispatch the highlight-fetcher agent

Spawn `highlight-fetcher` with:

```yaml
since: {since | null}
output_path: {vault_root}/{path}
vault_root: {vault_root}
run_date: {today, YYYY-MM-DD, local}
naming_pattern: {naming.pattern}
```

Single dispatch — one stream, one agent.

### 4. Aggregate

Read back the agent's counts and the list of files written.

---

## File shape

```yaml
---
type: raw
status: inbox
source: readwise
created: {YYYY-MM-DD of run}
title: "{source title}"
author: "{author}"
category: {books | articles | tweets | podcasts | supplementals}
source_url: "{cleaned url, or empty for forwarded email}"
readwise_book_id: {id}
highlight_ids: [{id}, ...]
tags: [raw, inbox, readwise, highlight]
---
```

Body: `# {title}`, `Source: {url}`, `## Highlights` (one blockquote per
highlight in reading order, `**Note:**` under annotated ones), `## Context`,
empty `## Notes`. Full spec lives in `agents/highlight-fetcher.md`.

---

## Idempotency contract

- **Join key:** every ID in the `highlight_ids` frontmatter lists of
  `{path}`. Swept once at run start.
- **Already-captured highlight → skip.**
- **New highlights on an already-pulled source → new dated file.** The
  earlier file is never read for merge, never appended to, never touched.
- **Slug collisions:** suffix `-2`, `-3`.
- **No deletes** for upstream-deleted highlights.

---

## Resilience

- `readwise` MCP missing or auth failure: abort, print re-auth instruction.
- Empty window: report `0 new`, exit zero. Normal for a quiet day.
- Per-source failure: log, count, continue.

---

## Report

```
PULL HIGHLIGHTS — DD-MM-YYYY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Window:      {since-date | full history} → today
Highlights:  {N} new in {N} source files, {N} unchanged, {N} skipped
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Files written:  [absolute paths]
Errors:         [list, if any]
```
