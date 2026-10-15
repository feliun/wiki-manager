---
name: slack-fetcher
description: >
  Fetches the Slack messages the user marked with a reaction emoji (default
  `:brain:`) via the `claude_ai_Slack` MCP server and writes one file per
  message to {output_path}/{YYYY-MM-DD} {channel} {slug}.md. Scoped to
  messages dated the run day (`on:{run_date}`) and to reactions the user
  placed themselves (`hasmy:`, never `has:`). Idempotent — keyed on the
  `slack_channel_id` + `slack_ts` pair, so a message already captured is
  never re-written and existing files are never touched. Threads are
  captured whole.
subagent_type: general-purpose
---

# Agent: Slack Fetcher

**Role:** Collect every message carrying the user's trigger reaction, and
persist one file per message to
`{output_path}/{YYYY-MM-DD} {channel} {slug}.md`.

Use the **`claude_ai_Slack`** MCP server for every Slack call. It is the only
configured client with a search tool. The native `slack` MCP server exposes
`slack_get_channel_history` and posting only — it cannot find reacted
messages and is not a fallback. Never substitute `curl` or a library client.

**Inputs (passed by `/pull-slack`, or directly by `/cob` Phase 0):**

- `trigger_emoji` — emoji name without colons, e.g. `brain`
- `on_date` — `YYYY-MM-DD` to scope to one day, or `null` for full history
- `output_path` — absolute directory (must exist or be creatable)
- `vault_root` — absolute path
- `channel_types` — comma-separated, e.g. `public_channel,private_channel,mpim,im`
- `only_my_channels` — boolean
- `include_thread` — boolean
- `naming_pattern` — e.g. `{date} {channel} {slug}`
- `slug_max_chars` — integer

---

## Bootstrap

1. Create `{output_path}` if absent:
   ```bash
   mkdir -p {output_path}
   ```

2. Reachability is proven by step 2's first call. If it fails with an auth or
   connection error, abort with:
   `claude_ai_Slack MCP unreachable — reconnect the Slack connector and retry`.
   Do **not** fall back to the native `slack` server; it cannot answer this
   query and would return a plausible-looking but wrong result set.

---

## Process

### 1. Build the existing-identity index (idempotency)

Single sweep at run start. Read the `slack_ts:` and `slack_channel_id:`
frontmatter lines of every `.md` in `{output_path}` and collect the pairs
into one set:

```bash
find -L {output_path} -name '*.md' -print0 | while IFS= read -r -d '' f; do
  ts=$(grep -m1 '^slack_ts:' "$f" </dev/null | sed 's/^slack_ts: *//; s/"//g')
  ch=$(grep -m1 '^slack_channel_id:' "$f" </dev/null | sed 's/^slack_channel_id: *//')
  [ -n "$ts" ] && echo "$ch|$ts"
done
```

`find -L`, never `grep -R` — the folder may sit behind a symlink, and BSD
grep does not descend through one it meets while walking. `</dev/null` keeps
the loop's stdin from being eaten.

**The join key is `channel_id` + `ts`.** `ts` alone is near-unique in
practice but is only guaranteed unique per channel. Not the filename: slugs
collide and get suffixed, so filename equality proves nothing.

### 2. Search the reacted set

Build the query as `hasmy::{trigger_emoji}:` plus, when `on_date` is set,
` on:{on_date}`:

```
mcp__claude_ai_Slack__slack_search_public_and_private(
  query            = "hasmy::{trigger_emoji}: on:{on_date}",   # omit `on:` when on_date is null
  channel_types    = {channel_types},
  only_my_channels = {only_my_channels},
  sort             = "timestamp",
  sort_dir         = "desc",
  include_context  = false,
  response_format  = "detailed",
  limit            = 20
)
```

> **`hasmy:`, never `has:`.** `hasmy::{emoji}:` matches reactions the
> authenticated user placed. `has::{emoji}:` matches that emoji from anyone,
> so in a shared workspace a teammate's reaction silently becomes a vault
> capture the user never chose. They return disjoint sets, not overlapping
> ones — measured 2026-10-15 in #ai-stuff, `has::eyes:` returned six
> colleague-marked messages from 7–14 Oct and `hasmy::eyes:` six different
> ones of the user's own going back to February, with zero intersection.
> A `has:` result set looks entirely plausible, which is what makes the
> substitution dangerous.

> **`on:` filters the MESSAGE date, not the reaction date** — the reaction
> timestamp is not exposed anywhere in the API surface. A message marked
> today but posted last week carries last week's date and will not match
> `on:{today}`. This is a deliberate, user-chosen scope (capture-as-you-read),
> not an oversight: do not "fix" it by widening the window. Users recover an
> old capture with `--on YYYY-MM-DD` or `--all`, which is what `on_date:
> null` is for.
>
> Use `on:`, not an `after:`/`before:` pair or the `after`/`before` params —
> `on:` is exact and single-valued. Verified 2026-10-15: `on:2026-09-28`
> returned exactly that day's marked message and `on:2026-09-27` returned
> none.

> **Do NOT use `is:saved`.** It parses, matches everything, and returns the
> most recent messages in the workspace — byte-identical to a bare
> `after:`-only query sorted by timestamp, bot alerts included. It looks like
> a working query and is not one.

`limit` caps at **20**. Paginate: pass the `cursor` from `pagination_info`
until it reports end of results. Collect all hits before writing anything.

Each detailed hit gives: `Channel` name + ID, `From` name + email + user ID,
`Time` (workspace-local), `Message_ts`, `Reply count`, `Permalink`, `Text`.

### 3. Filter against the index

Drop any hit whose `channel_id|ts` is already in the step-1 set. Count these
as `unchanged`. Everything surviving is new.

If nothing survives, stop here and report `new_files: 0`. This is the normal
case on a day with no new reactions, and will be the common outcome — a
single-day scope means most runs find nothing.

### 4. Fetch threads

For each surviving hit with `Reply count` > 0, when `include_thread` is true:

```
mcp__claude_ai_Slack__slack_read_thread(
  channel_id      = {hit channel ID},
  message_ts      = {hit Message_ts},
  response_format = "concise"
)
```

`Reply count` is already in the search hit — do **not** call `read_thread`
for messages that report 0, it is a wasted round trip per capture.

A hit may itself be a *reply* rather than a thread parent. `read_thread`
requires the **parent** ts; the hit's permalink carries it as the
`thread_ts` query param. Parse it from the permalink and prefer it over
`Message_ts` when the two differ — passing a reply's ts returns just that
message, which silently produces the context-free capture `include_thread`
exists to prevent.

### 5. Resolve the channel name

The hit's `Channel` field carries the name for channels. For DMs and group
DMs it may be an ID or blank. Fall back in order: the hit's `Channel` name →
`mcp__claude_ai_Slack__slack_read_user_profile` for the other party on a DM
(`dm-{username}`) → the literal channel ID. Never leave the filename segment
empty.

### 6. Compose each file

Filename: `{date} {channel} {slug}.md` where `{date}` is the **message**
date (`YYYY-MM-DD`, from `Time`), `{channel}` the resolved name without `#`,
and `{slug}` the message text slugified — lowercased, accents folded, Slack
markup (`<@U…>`, `<http…|label>`, `:emoji:`) stripped first, hyphenated,
truncated at `slug_max_chars` on a word boundary. On collision within the
output folder, suffix `-2`, `-3`.

Frontmatter:

```yaml
---
type: raw
status: inbox
source: slack
created: {YYYY-MM-DD of the message}
slack_ts: "{Message_ts}"
slack_channel_id: {channel ID}
slack_channel: {channel name}
slack_author: "{From display name}"
slack_author_email: "{From email, omit the line if absent}"
slack_permalink: "{Permalink}"
slack_thread: {true | false}
tags: [raw, inbox, slack]
---
```

`slack_ts` **must be quoted** — unquoted, `1790604733.553209` is a YAML float
and loses trailing-zero precision, breaking the dedupe key on the next run.

Body:

```markdown
# #{channel} — {author}, {YYYY-MM-DD}

Source: {permalink}

## Message

{message text, Slack markup resolved to plain markdown}

## Thread

> **{author}** {HH:mm}
> {reply text}

> **{author}** {HH:mm}
> {reply text}

## Context

- Channel: #{channel}
- Captured via the `:{trigger_emoji}:` reaction

## Notes
```

- Omit `## Thread` entirely when there are no replies — an empty heading
  reads as a failed fetch.
- Resolve Slack markup in all text: `<http://x|label>` → `[label](http://x)`,
  `<@U123|Name>` → `Name`, `<!channel>` → `@channel`. Leave `:emoji:` codes
  as-is; they carry tone.
- Keep message text verbatim otherwise. Do not summarize, translate, or
  tidy — `expand-raw-ideas` does that downstream, and it needs the original.
- `## Notes` is deliberately empty, for the user or `expand-raw-ideas`.

**Write path:** `obsidian create path="{relative path}" content="$BODY" </dev/null`
with the full note, frontmatter included (`create` does not prepend a
newline, so `---` stays at byte 0). Attempt the CLI first every time — a
predicted escaping problem is not a verified failure. Only on a verified
mangle/truncation fall back to `Write`, and report the deviation.

### 7. Verify (in a separate invocation)

Obsidian writes are asynchronous; never verify in the same shell command that
wrote. In a later call, confirm per file: it exists, line 1 is `---`, the
`slack_ts` reads back quoted and intact, and no `{name} 1.md` fork exists.
A file missing after verification counts as `error`.

### 8. Counts

- `new_files` — messages written and verified.
- `threads_expanded` — of those, how many pulled replies.
- `unchanged` — hits skipped because their `channel_id|ts` was already indexed.
- `error` — search/read/write/parse failure.

---

## Output

```
slack-fetcher complete
trigger:          :{trigger_emoji}:  (own reactions only)
scope:            {on_date | full history}
reacted_total:    {N}   (marked messages in scope, all pages)
new_files:        {N}
threads_expanded: {N}
unchanged:        {N}
errors:           [list with channel + ts + reason]
files_written:    [absolute paths, new only]
```

Always report `reacted_total` and `scope` alongside `new_files`. They are
the only signals distinguishing "nothing marked today" from "the search
silently returned nothing" — the two are identical in `new_files` alone, and
with a single-day scope the zero case is routine rather than suspicious.

---

## Resilience

- `claude_ai_Slack` MCP unreachable / auth failure → abort, print the
  reconnect instruction. Never silently fall back to the native server.
- Zero reacted messages → `new_files: 0`, exit cleanly. Normal case.
- Thread fetch fails for one hit → write the message without `## Thread`,
  log it, continue.
- Per-message write/parse error → log, count, continue with the next.

---

## Anti-patterns

- Do NOT substitute `has:` for `hasmy:`. It captures teammates' reactions.
- Do NOT widen the `on:{on_date}` scope to "catch" messages marked today but
  posted earlier. That trade is the user's, already made; the escape hatches
  are `--on` and `--all`.
- Do NOT use `is:saved`. It silently matches everything.
- Do NOT fall back to the native `slack` MCP server. It has no search.
- Do NOT key idempotency on the filename. Slugs collide; the
  `channel_id` + `ts` pair is the only join key.
- Do NOT leave `slack_ts` unquoted in frontmatter.
- Do NOT append to or edit an existing capture file — it may already be
  ingested (`status: done`) or user-edited.
- Do NOT remove the user's reaction. A single-day scope already bounds the
  pull, so there is nothing to gain, and the reaction is the user's own
  visible record in Slack of what they marked.
- Do NOT summarize message text at fetch time. `/ingest` needs the original.
- Do NOT report success without the step-7 verification.
