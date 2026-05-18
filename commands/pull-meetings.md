---
name: wiki-manager:pull-meetings
description: >
  Fetch your Granola meetings into records/meetings/ for the vault.
  Defaults to the past 24 hours. Idempotent: each meeting is keyed on
  immutable `granola_id` frontmatter, so re-runs are skip-if-exists and
  legacy meeting files in the same folder are never disturbed.
---

# Pull Meetings

Pull your Granola meetings via the `granola` MCP server and persist
them flat. Output path comes from `granola.yaml`:

- meetings:  `{vault_root}/{path}{YYYY-MM-DD} {slug-title}.md`

Granola-sourced files coexist with legacy meeting files in the same
folder (currently `records/meetings/`). The two are distinguished by
the `source: granola` frontmatter and the `granola_id` field, which is
also the idempotency join key — re-running this command never touches
existing files, whether legacy or granola-sourced.

**Granola API access tool: the `granola` MCP server.** Never substitute
`curl` or library clients — the MCP server is the only client
configured with the local auth required for these endpoints. If the
MCP is absent or auth fails, abort with a clear error rather than
partial-fetching.

---

## Args

- `--days N` — lookback window in days. Overrides `granola.window_days`.
- `--since YYYY-MM-DD` — explicit start date (overrides `--days`).
- `--folder <id>` — scope to a single Granola folder.
- `--folders <id1,id2,...>` — scope to multiple Granola folders.

Find folder IDs with one MCP call:

```
mcp__granola__list_meeting_folders
```

Returns the list of folders the user has defined in Granola. Without a
folder flag, the default `list_meetings` returns every meeting in the
window; folder membership is not stamped onto the resulting files.

---

## Process

### 1. Resolve config

Invoke the `manifest-resolver` skill to load `vault-paths` and
`granola`. From the resolved values capture:

- `vault_root` — absolute path (from vault-paths)
- `path` — relative output dir (from granola), trailing slash
- `window_days`
- `content` — list of body fields (subset of `[summary, private_notes]`)
- `naming.pattern` and `naming.date_format`

### 2. Compute the `since` boundary

`since` = `--since` > `--days` > `granola.window_days`.

Convert to RFC 3339 UTC at midnight: `YYYY-MM-DDT00:00:00Z`. This is
the only window; there is no per-stream split (unlike `/pull-tweets`).

### 3. Determine folder scope

Parse `--folder` / `--folders` into a list of folder IDs; absent →
`null` (= all meetings, unscoped).

### 4. Dispatch the meeting-fetcher agent

Spawn `meeting-fetcher` with:

```yaml
since: {since}
output_path: {vault_root}/{path}
vault_root: {vault_root}
content_fields: {content}
naming_pattern: {naming.pattern}
date_format: {naming.date_format}
folder_ids: {folder_ids | null}
```

Single dispatch — folder iteration happens inside the agent, not at
this layer. (Unlike `/pull-tweets`, which has two independent streams
worth parallelising, `/pull-meetings` has one stream regardless of
folder count.)

### 5. Aggregate

Read back the agent's counts (`new`, `unchanged`, `errors`) and the
list of files written.

---

## File shape

The fetcher writes:

```yaml
---
type: meeting
source: granola
created: {YYYY-MM-DD of run}
date: {YYYY-MM-DD HH:MM of meeting start, local time}
granola_id: {uuid}
tags: [meeting, granola]
---
```

Body sections: `# {title}`, `## Attendees`, `## Summary` (if configured),
`## Private Notes` (if configured), `## Context`. Full spec lives in
`agents/meeting-fetcher.md`.

---

## Idempotency contract

- **Filename:** `{YYYY-MM-DD} {slug-title}.md`. Human-scannable; not
  used as the idempotency key.
- **Join key:** `granola_id` in frontmatter. The agent builds a single
  set of existing IDs at run start by sweeping the output folder.
- **Existing meeting → skip.** Do not read, do not merge, do not touch.
  The body sections (Summary, Private Notes) may contain user edits.
- **Legacy files coexist.** Files without `granola_id` are invisible to
  the join — they neither match nor are touched.
- **Slug collisions** (different UUIDs, same filename): suffix `-2`,
  `-3` to the slug.
- **No deletes.** Upstream-deleted meetings stay in the vault — the
  archive is non-destructive.
- **No in-place mutations.** No folder-stamping like
  `bookmark-fetcher` — Granola folder membership is not persisted to
  the file.

---

## Resilience

- `granola` MCP missing or auth failure: abort. Print re-auth
  instruction and exit non-zero.
- `list_meetings` returns empty: report `new: 0, unchanged: 0`, exit
  zero. Normal for a quiet window.
- `get_meetings` 10-per-call cap: agent paginates client-side.
- Per-meeting failure: log, count, continue.

---

## Report

```
PULL MEETINGS — DD-MM-YYYY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Window:    {since-date} → today
Meetings:  {N} new, {N} unchanged   (scope: all | folder:{ids})
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Files written:  [absolute paths]
Errors:         [list, if any]
```
