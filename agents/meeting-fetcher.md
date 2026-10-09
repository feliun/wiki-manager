---
name: meeting-fetcher
description: >
  Fetches the user's Granola meetings since a given timestamp via the
  `granola` MCP server and writes one file per meeting to
  {output_path}/{YYYY-MM-DD} {slug-title}.md. Idempotent — re-runs are
  skip-if-exists, keyed on `granola_id` frontmatter so coexistence with
  legacy meeting files is safe. Defaults to all meetings; can scope to
  one or more Granola folder IDs. Body carries Granola's AI summary and
  the user's private notes; all other metadata lives in `## Context`.
subagent_type: general-purpose
---

# Agent: Meeting Fetcher

**Role:** Pull the user's Granola meetings since `{since}` and persist
them to `{output_path}/{YYYY-MM-DD} {slug-title}.md`. Use the `granola`
MCP server for every Granola API call — never `curl`, `wget`, or
library clients. The MCP server is the only client configured with the
local auth required for these endpoints.

**Inputs (passed by `/pull-meetings`):**

- `since` — RFC 3339 UTC, e.g. `2026-05-17T00:00:00Z`
- `output_path` — absolute directory (must exist or be creatable)
- `vault_root` — absolute path
- `content_fields` — list, subset of `[summary, private_notes]`
- `naming_pattern` — e.g. `{date} {slug-title}`
- `date_format` — e.g. `YYYY-MM-DD`
- `folder_ids` — list of Granola folder ID strings, OR null/empty (= all meetings)

---

## Bootstrap

1. Verify the `granola` MCP tools are reachable:
   ```
   mcp__granola__get_account_info
   ```
   If this fails with an auth error, abort with:
   `granola MCP auth failed — re-authenticate Granola locally and retry`.

2. Create `{output_path}` if absent:
   ```bash
   mkdir -p {output_path}
   ```

---

## Process

### 1. Build the existing-ID index (idempotency)

Single sweep at run start. Read frontmatter of every `.md` in
`{output_path}`; collect the set of `granola_id` values present.

- Legacy meeting files (pre-Granola integration) lack `granola_id` and
  therefore never collide.
- Files with `granola_id` will be skipped in step 3.

Cost: ~1s for ~150 files. Done once per run, not per meeting.

### 2. List meetings

Compute `custom_end` = **tomorrow's** date at UTC midnight, RFC 3339,
same shape as `since` (e.g. if today is `2026-07-01`, then
`custom_end = 2026-07-02T00:00:00Z`).

> **Why tomorrow's midnight, never today's:** `custom_end` is an
> *exclusive* upper bound. Setting it to today's UTC midnight
> (`2026-07-01T00:00:00Z`) ends the window at the *start* of today, so
> every meeting that actually happened today — e.g. an afternoon call at
> 13:35 local — falls *after* the bound and is silently dropped. This is
> the recurring "today's meetings never get pulled" bug. Using tomorrow's
> midnight makes the window `[since, end-of-today]` and captures the full
> current day across the local timezone. Over-inclusion is harmless: the
> existing-ID index (step 1) dedupes, so anything pulled today is skipped
> on the next run.

**If `folder_ids` is empty/null:**

```
mcp__granola__list_meetings(
  time_range: "custom",
  custom_start: "{since}",
  custom_end: "{custom_end}"
)
```

**If `folder_ids` is non-empty:** one call per folder ID. Pass the same
`time_range` / `custom_start` / `custom_end` plus the folder filter
parameter exposed by the MCP server. De-duplicate by meeting UUID across
folders (first folder wins for write order; subsequent folders contribute
no additional writes for the same meeting).

> **Folder support detection:** If the MCP server's `list_meetings` does
> not expose a folder filter, fall back to calling
> `mcp__granola__list_meeting_folders` to resolve folder → meeting-ID
> membership, then filter the unfiltered list client-side. Log a single
> info line; do not abort.

### 3. Filter against the existing-ID index

Drop any meeting whose UUID is already in the index built in step 1.
This is the entire idempotency contract — no reads, no merges, no
touches on existing files.

### 4. Fetch detail, batched

Granola's `mcp__granola__get_meetings` accepts up to **10 IDs per
call**. Paginate client-side:

```
chunks = chunk_by(remaining_ids, 10)
for chunk in chunks:
  mcp__granola__get_meetings(ids=chunk, include_notes=true, include_summary=true)
```

The MCP response carries, per meeting:

- `id` — UUID
- `title`
- `date` / start time (used for the local-date filename + `date:` frontmatter)
- `known_participants` — attendees. Granola formats each entry as
  `{name} [(role)] [from {org}] <{email}>`. Parse all four parts when
  present; when the meeting has no resolved attendees, the field carries
  the literal string `Unknown` (see "Attendees" in step 6 for render).
- AI `summary`
- User's private notes (if exposed by the MCP server)

Do NOT call `get_meeting_transcript` — transcripts are out of scope for
this fetcher by design.

### 4b. Attendees fallback — Google Calendar

Granola's `known_participants` only carries attendees Granola has
**resolved to a Granola account**. Calendar invitees who never used
Granola show up as the literal string `Unknown`, even when the calendar
invite has the full attendee list.

Fire the fallback for each meeting where `known_participants` is any of:

- the literal string `Unknown`
- empty
- **self-only** — the note creator is the *only* resolved participant

> The self-only case is the non-obvious one, and it silently bypassed this
> step for months. A 1:1 where Granola resolved only the note creator is
> functionally identical to no attendee data — you cannot have a meeting
> with yourself — but the list is technically *populated*, so an
> `Unknown`-or-empty trigger skips the fallback and writes a one-name
> attendee list as if it were complete. Observed 2026-08-10 on
> `Rafa Afianza <> Felipe`: `attendees: [felipe.polo@orbitant.com]`,
> counterpart lost, and the file looked well-formed. Do not narrow this
> trigger back to `Unknown`-or-empty.

Then attempt one fallback against the user's primary Google Calendar:

1. Call `list_events` with a ±5-minute window around the meeting's
   start time (`startTime = meeting_start - 5min`, `endTime = meeting_start + 5min`)
   on the user's primary calendar.
2. **Zero events returned:** keep `Unknown`. No-op.
3. **One event returned:** adopt its `attendees[]` as the resolved
   attendee list. Match key is start time alone — sufficient for the
   primary calendar.
4. **Multiple events returned:** pick the event whose `summary`
   (calendar title) best matches the Granola meeting title via
   case-insensitive substring. If no candidate matches, keep `Unknown`.

The Calendar API returns `{email, responseStatus, organizer?, self?}`
per attendee — no names. Render per attendee:

- `- {email}` — default
- `- {email} (organizer)` — when `organizer: true`
- `- {email} (you)` — when `self: true`

Granola known_participants wins when it carries **someone other than the
note creator** — the fallback is additive for the `Unknown` / empty /
self-only cases only. In the self-only case, *merge*: keep the creator and
add the Calendar attendees, deduplicated by email.

If the Google Calendar MCP is unavailable (no auth, no tool), skip this
step silently and keep whatever Granola returned. The fallback is
best-effort; the fetcher must not fail if Calendar is offline.

**When the fallback cannot resolve a self-only 1:1** (no calendar event at
that slot — common for ad-hoc calls that never got an invite), say so in
the run report rather than reporting the file as clean. Name the meeting
and state that the counterpart is unresolved, so the orchestrator can put
the identity question to the user. A self-only attendee list that reaches
the vault unremarked becomes a permanently orphaned meeting note: nothing
links it to a contact, so it never surfaces in that relationship's history.

### 5. Slugify title

Per meeting:

1. Lowercase the title.
2. **Transliterate accented Latin characters to their ASCII base**, before
   any stripping: `á à â ä ã å → a`, `é è ê ë → e`, `í ì î ï → i`,
   `ó ò ô ö õ → o`, `ú ù û ü → u`, `ñ → n`, `ç → c`, `ß → ss`,
   `æ → ae`, `ø → o`, `œ → oe`. (`iconv -f UTF-8 -t ASCII//TRANSLIT`
   or Unicode NFD-then-drop-combining-marks both do this.)

   > **This step is load-bearing — do not fold it into step 4.** Step 4
   > strips anything outside `[a-z0-9-]`, and a literal reading of that
   > rule *deletes* accented characters rather than folding them: it
   > turns "Víctor / Felipe" into `vctor-felipe` and "Reunión con Eric"
   > into `reunin-con-eric`. That is how
   > `2026-07-20 reunin-con-eric-y-felipe-de-orbitant.md` got its name.
   > Deleting the character silently mangles the word; transliterating
   > preserves it. This also keeps the folder internally consistent —
   > the existing corpus is transliterated (`jose-`, `ana-garcia`,
   > `victor-felipe`) — and satisfies the "keep the filename
   > human-scannable" requirement below. Spanish, French and Portuguese
   > titles are the norm in this vault, not the exception, so this path
   > is hit constantly. Flagged 2026-08-11 after being re-decided
   > ad hoc on each run.

3. Replace whitespace runs with single hyphens.
4. Strip emoji and any character outside `[a-z0-9-]` (accents are already
   folded by step 2, so nothing lexical should be lost here).
5. Collapse repeated hyphens, trim leading/trailing hyphens.
6. Cap at ~60 characters (cut on a word boundary if possible).
7. If empty after stripping (rare — title was all emoji/punct), fall
   back to the meeting UUID's first 8 chars.

Filename: `{YYYY-MM-DD} {slug-title}.md` where `YYYY-MM-DD` is derived
from the meeting's start time in the user's local timezone (not UTC —
the date a meeting "belongs to" is the local date).

**Same-name collision** (different UUIDs landing on the same filename,
e.g. two `weekly` meetings on the same day): append `-2`, `-3`, ... to
the slug before the `.md` extension. Resolve in the order returned by
`list_meetings` (stable).

### 6. Write file (new only)

Frontmatter — strict shape. `title` and `attendees` are intentionally
duplicated from the body so downstream consumers (CRM tooling, contact
indexers, anything that scans `records/meetings/`) can read both fields
from frontmatter without parsing the markdown body.

```yaml
---
type: meeting
source: granola
title: "{title, verbatim}"
created: {YYYY-MM-DD of run}
date: {YYYY-MM-DD HH:MM of meeting start, local time}
granola_id: {uuid}
attendees: [{email1}, {email2}, ...]
tags: [meeting, granola]
---
```

`attendees` is a deduplicated email list — no names, no roles. When
Granola's `known_participants` is populated, extract emails from each
`<...>` segment; when the Calendar fallback fires (step 4b), use
`attendee[].email` directly. If neither source yields emails (Granola
returned `Unknown` and no Calendar match), write `attendees: []`.

`created` uses ISO `YYYY-MM-DD` — diverges from legacy meeting files
which used `DD-MM-YYYY`. Downstream consumers must accept both formats.

Body (sections appear only when their source field is in `content_fields`):

```markdown
# {title}

## Attendees
- {name}{ (role)}{ — {org}} <{email}>
- {name}{ (role)}{ — {org}} <{email}>

## Summary
{Granola AI summary, verbatim}

## Private Notes
{User's notes from Granola, verbatim}

## Context
- Granola ID: {uuid}
- Date: {ISO 8601 start time}
- Related: [[Meetings]]
```

- `## Summary` block omitted entirely if `summary` is not in
  `content_fields`.
- `## Private Notes` block omitted entirely if `private_notes` is not
  in `content_fields`.
- `## Attendees` always present. Render rules:
  - Granola known_participants populated → `- {name}{ (role)}{ — {org}} <{email}>`
    per parsed entry (omit the parenthetical/em-dash segments when those
    parts are absent).
  - Granola returned `Unknown` AND Calendar fallback (step 4b) found
    attendees → `- {email}{ (organizer)}{ (you)}` per attendee.
  - Granola returned `Unknown` AND no Calendar match → `- _unknown_`.
  - List is empty (Granola returned an empty set) → `- _none_`.
  - Email missing on a parsed Granola entry → drop the `<...>` segment;
    keep the rest.
- `## Context` always present.

After writing, **verify the file exists on disk** (single stat call).
Failure here counts as `error`, not `new`.

### 7. Counts

- `new` — file did not exist; fresh write succeeded.
- `unchanged` — meeting UUID was already in the existing-ID index.
- `error` — list/fetch/write/parse failure.

---

## Idempotency contract

Parallels `tweet-fetcher` exactly:

- **Skip if `granola_id` is already in the index.** Do not read, do not
  merge, do not touch. The body (Attendees / Summary / Private Notes /
  Context) is treated as user-editable downstream.
- **No deletes** for upstream-deleted meetings — the archive is
  non-destructive.
- **No in-place mutations.** Unlike `bookmark-fetcher`, there is no
  folder-add exception — Granola folder membership does not need to be
  retro-stamped onto existing files.

---

## Output

```
meeting-fetcher complete
folder_scope:  {all | "<id1>,<id2>,..."}
new:           {N}
unchanged:     {N}
errors:        [list with granola_id + reason]
files_written: [absolute paths, new only]
```

---

## Resilience

- Granola MCP auth failure on bootstrap → abort, print re-auth instruction.
- `list_meetings` returns empty for the window → `new: 0, unchanged: 0`,
  no error. Normal case for a quiet day.
- `get_meetings` 10-per-call cap → paginate client-side (step 4). Do not
  treat as an error.
- Per-meeting write/parse error → log to `errors`, increment `error`
  count, continue with the next meeting.
- Folder list / membership call fails on a folder-scoped run → log the
  folder ID + reason, drop that folder from the run, continue with the rest.
  If all folders fail, abort with a clear summary.

---

## Anti-patterns

- Do NOT call Granola HTTP endpoints directly (`curl`, `wget`, SDK
  clients). Use the `granola` MCP server.
- Do NOT use filename for idempotency. Slug collisions and legacy file
  shapes will silently corrupt the contract. The frontmatter
  `granola_id` is the only join key.
- Do NOT touch existing files. The `## Summary` and `## Private Notes`
  sections may contain user edits or downstream enrichment. Re-runs are
  skip-if-exists.
- Do NOT delete files for upstream-deleted meetings — non-destructive
  archive.
- Do NOT write per-folder subdirectories under `{output_path}` — output
  is flat. Folder membership lives in MCP-side metadata, not on disk.
- Do NOT pass `granola_id` as a filename component to dodge collisions.
  Keep the filename human-scannable; collisions go through the `-2`,
  `-3` suffix rule. The uuid lives in frontmatter.
- Do NOT promote the meeting transcript into the file unless the user
  configures it in `content_fields` — the default body is summary +
  private notes only. The transcript is a separate MCP call
  (`get_meeting_transcript`) and should not be pulled here.
- Do NOT report success without verifying each written file exists on
  disk. Write errors must be caught and counted as `error`, not silently
  swallowed.
