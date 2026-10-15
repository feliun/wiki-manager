---
name: wiki-manager:pull-slack
description: >
  Fetch the Slack messages you marked yourself with a reaction emoji
  (default `:brain:`) into raw/slack/ for the ingest pipeline. Scoped to
  today's messages; `--on` / `--all` widen it. One file per message, threads
  captured whole. Idempotent: keyed on the `slack_channel_id` + `slack_ts`
  pair, so re-runs never duplicate a capture and never touch existing files.
---

# Pull Slack

React to a Slack message with your trigger emoji; this command turns it into
a raw capture. Only **your own** reactions count, and only messages dated
**today**. Output path comes from `slack.yaml`:

- captures: `{vault_root}/{path}{YYYY-MM-DD} {channel} {slug}.md`

Files land with `status: inbox`, so `/ingest` expands each one into a wiki
note — the messages are the idea, and links inside them are references.

**Slack API access tool: the `claude_ai_Slack` MCP server.** It is the only
configured client with a search tool. The native `slack` MCP server does
channel history and posting only and cannot find reacted messages — it is
not a fallback. If the connector is absent or auth fails, abort with a clear
error rather than partial-fetching.

---

## Args

- `--on YYYY-MM-DD` — capture messages dated that day instead of today. Use
  to recover a day whose run was missed, or to pull in something old you
  marked after the fact.
- `--all` — no date filter: the entire marked history, paginated. Safe to
  re-run; already-captured messages are skipped.
- `--emoji NAME` — trigger emoji without colons. Overrides
  `slack.trigger_emoji`. Use to pull a one-off set marked with a different
  reaction.
- `--channels TYPES` — comma-separated `channel_types`. Overrides
  `slack.channel_types`. e.g. `--channels public_channel,private_channel`
  to exclude DMs for one run.
- `--no-threads` — capture only the marked message, skipping reply fetches.

---

## Scope: your reactions, today's messages

**Your reactions only.** The query uses `hasmy::{emoji}:`, which matches
reactions *you* placed. The sibling modifier `has::{emoji}:` matches that
emoji from anyone — in a shared workspace that would quietly fill the vault
with captures a teammate chose. The two return disjoint sets, not
overlapping ones: measured in #ai-stuff, `has::eyes:` returned six
colleague-marked messages from 7–14 Oct while `hasmy::eyes:` returned six
different ones of your own going back to February.

**Today's messages only.** The query appends `on:{run date}`.

The thing to know about that: `on:` filters the **message** date. Slack does
not expose the **reaction** date anywhere, so a message you post-date — mark
today, posted last week — carries last week's stamp and will not be picked
up. Capture-as-you-read works; marking up an old thread needs `--on` or
`--all`.

The upside is that the marked set never has to be re-scanned. The pull stays
O(one day) however long the emoji accumulates history, and you never have to
un-react to keep it cheap.

**If a daily run is missed**, that day's captures are not lost — they are
just not in today's scope. `--on YYYY-MM-DD` picks them up whenever you
notice, and dedupe makes the catch-up safe.

---

## Process

### 1. Resolve config

Invoke the `manifest-resolver` skill to load `vault-paths` and `slack`.
Capture:

- `vault_root` — absolute path (from vault-paths)
- `path` — relative output dir (from slack), trailing slash
- `trigger_emoji`, `day_scope`, `channel_types`, `only_my_channels`,
  `include_thread`
- `naming.pattern` and `naming.slug_max_chars`

Apply the arg overrides over the resolved values, then resolve `on_date`:
`--all` → `null` > `--on DATE` → that date > `day_scope: today` → today's
local date > `day_scope: all` → `null`.

### 2. Dispatch the slack-fetcher agent

Spawn `slack-fetcher` with:

```yaml
trigger_emoji:    {trigger_emoji}
on_date:          {YYYY-MM-DD | null}
output_path:      {vault_root}/{path}
vault_root:       {vault_root}
channel_types:    {channel_types}
only_my_channels: {only_my_channels}
include_thread:   {include_thread}
naming_pattern:   {naming.pattern}
slug_max_chars:   {naming.slug_max_chars}
```

Single dispatch — one stream, one agent.

### 3. Aggregate

Read back the agent's counts and the list of files written. Report
`reacted_total` and the scope as well as `new_files`: they are the only
things separating "nothing marked today" from "the search returned nothing",
which look identical otherwise. With a one-day scope, zero is the routine
outcome, not a red flag.

---

## File shape

```yaml
---
type: raw
status: inbox
source: slack
created: {YYYY-MM-DD of the message}
slack_ts: "{message ts, quoted}"
slack_channel_id: {channel ID}
slack_channel: {channel name}
slack_author: "{display name}"
slack_author_email: "{email, omitted if absent}"
slack_permalink: "{permalink}"
slack_thread: {true | false}
tags: [raw, inbox, slack]
---
```

Body: `# #{channel} — {author}, {date}`, `Source: {permalink}`,
`## Message`, `## Thread` (omitted when there are no replies), `## Context`,
empty `## Notes`. Full spec lives in `agents/slack-fetcher.md`.

---

## Idempotency contract

- **Join key:** the `slack_channel_id` + `slack_ts` pair across the
  frontmatter of `{path}`. Swept once at run start with `find -L`.
- **Already-captured message → skip.** Never re-read for merge, never
  appended to, never touched.
- **New replies on an already-captured thread do NOT reopen the file.** The
  capture is a snapshot of the thread at capture time. React again to pull a
  fresh one if the discussion moved on.
- **Slug collisions:** suffix `-2`, `-3`.
- **No deletes**, and no un-reacting on the user's behalf.
- **Re-running the same day is free.** `/cob` and a manual `/pull-slack` on
  the same afternoon produce one capture, not two.

---

## Resilience

- `claude_ai_Slack` MCP missing or auth failure: abort, print the reconnect
  instruction. Do not fall back to the native `slack` server.
- Empty reacted set: report `0 new`, exit zero. Normal for a quiet day.
- Per-message failure: log, count, continue.

---

## Report

```
PULL SLACK — DD-MM-YYYY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Trigger:   :{emoji}:  (your reactions only) across {channel_types}
Scope:     {YYYY-MM-DD | full history}
Reacted:   {N} marked in scope  →  {N} new, {N} already captured
Threads:   {N} expanded
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Files written:  [absolute paths]
Errors:         [list, if any]
```
