---
name: bookmark-fetcher
description: >
  Fetches the user's X bookmarks since a given timestamp via the `xurl`
  CLI and writes one file per tweet to {output_path}/{tweet_id}.md
  (flat — no per-folder subdirectories). Defaults to all bookmarks; can
  scope to one or more folder IDs. Folder-scoped runs resolve folder
  names from the X API and write both `bookmark_folder` (human-readable
  name) and `bookmark_folder_id` (stable join key). Idempotent —
  re-runs are skip-if-exists, with one allowed in-place mutation: a
  folder-scoped re-run may add the `bookmark_folder` / `bookmark_folder_id`
  pair to a file that lacked them. Telegram-style minimal frontmatter;
  all other metadata lives in the body under `## Context`.
subagent_type: general-purpose
---

# Agent: Bookmark Fetcher

**Role:** Pull the user's bookmarks (filtered by tweet-creation date and
optionally by folder), persist them flat to
`{output_path}/{tweet_id}.md`. Use `xurl` for **every** X API call —
bookmark endpoints require OAuth2 user-context auth which only `xurl` is
configured for. `curl` + bearer-token will silently 403 on these
endpoints.

**Inputs (passed by `/pull-tweets`):**

- `since` — RFC 3339 UTC
- `folder_ids` — list of folder ID strings, OR null/empty (= all bookmarks)
- `output_path` — absolute directory
- `vault_root` — absolute path

---

## Bootstrap

1. Verify `xurl` is on PATH; abort if missing.
2. `mkdir -p {output_path}`.

---

## Process

### 1. Resolve user ID

```bash
xurl "/2/users/me"
```

Extract `data.id` → `{user_id}`.

### 1b. Resolve folder ID → name map (folder-scoped runs only)

Skip this step entirely if `folder_ids` is empty/null — the default `/bookmarks` endpoint never writes folder fields anyway.

```bash
xurl "/2/users/{user_id}/bookmarks/folders?max_results=100"
```

Loop on `meta.next_token` (cap 10 pages). Build `{folder_id: folder_name}` from `data[].id` and `data[].name`.

Then, for every input `folder_id`:

- Found in map → record both ID and name; pass forward to step 5.
- Missing from map → log "folder {id} not found in user's folder list", drop from this run's endpoint set, count toward `error`.

If two folders in the map share the same `name`, **both keep their distinct IDs** but the second occurrence's name is suffixed: `"{name} (2)"`, `"{name} (3)"`, ... in the order returned by the API. The ID is the join key; the name is a label.

### 2. Determine endpoint set

The two routes are **shaped differently** at the X API level — the default route returns fully-hydrated tweets with pagination, while the folder route returns a flat list of IDs only. Step 3 handles each separately.

- `folder_ids` empty/null → default route: `/2/users/{user_id}/bookmarks` (paginated, accepts `tweet.fields`/expansions, full hydration in one call sequence).
- `folder_ids` non-empty → folder route, per resolved folder ID (i.e. those that survived step 1b): `/2/users/{user_id}/bookmarks/folders/{folder_id}` (flat `data: [{id}]` only — **no pagination, no `tweet.fields` / expansions support, no `max_results`**). Hydration happens in step 3B via `/2/tweets?ids=...`.

> Note: the variant `/2/users/{user_id}/bookmarks/folders/{folder_id}/tweets` (with `/tweets` suffix) returns a 404 / `request failed`. Don't use it. Verified empirically against the live API.

### 3. Fetch tweets

#### 3A. Default route (when `folder_ids` empty/null)

```bash
xurl "/2/users/{user_id}/bookmarks?max_results=100&tweet.fields=created_at,author_id,attachments,entities,referenced_tweets&expansions=author_id,attachments.media_keys,referenced_tweets.id,referenced_tweets.id.author_id&user.fields=username&media.fields=url,preview_image_url,type"
```

Loop on `meta.next_token` (append `&pagination_token={next_token}`). Cap at 50 pages as a safety bound. Each page is fully hydrated — proceed straight to step 4.

#### 3B. Folder route (when `folder_ids` non-empty)

Two phases per folder, then a single hydration pass.

**Phase 1 — collect IDs per folder:**

```bash
xurl "/2/users/{user_id}/bookmarks/folders/{folder_id}"
```

Returns `data: [{id}, {id}, ...]`. No pagination — the response contains the entire folder. Collect IDs into a per-folder list and a global de-duplicated set.

If a tweet appears in 2+ folders: the **first** folder ID (per input order) wins for the `bookmark_folder` write; subsequent folder responses re-encounter the same tweet ID and are no-ops at write time (step 5's mutation rule already protects existing files via the `bookmark_folder_id` existence check).

**Phase 2 — hydrate via tweet lookup, batched:**

```bash
xurl "/2/tweets?ids={id1},{id2},...,{idN}&tweet.fields=created_at,author_id,attachments,entities,referenced_tweets&expansions=author_id,attachments.media_keys,referenced_tweets.id,referenced_tweets.id.author_id&user.fields=username&media.fields=url,preview_image_url,type"
```

Batch size: up to 100 IDs per call. Loop until all collected IDs are hydrated. Carry forward each tweet's source-folder ID from phase 1 — the `/2/tweets` response does NOT carry folder membership, so the join must be maintained client-side.

### 4. Filter by `since` — client-side

The bookmarks endpoints accept no `start_time` parameter; filtering happens client-side post-hydration:

```
keep tweet iff tweet.created_at >= since
```

**Default route (3A) caveat — do not short-circuit pagination.** Pages return tweets in bookmarking order, not tweet-creation order. A page may interleave old and new tweets in arbitrary order (you might bookmark a 2-year-old tweet today, putting it at the top of page 1). Walk every page returned, filter on each, until `next_token` is absent or the safety cap is hit.

**Folder route (3B) — no pagination concern.** The folder ID-list endpoint returns the entire folder in one response, so there is no early-exit risk. Filter post-hydration.

> Semantic note: "past 7 days" filters by tweet creation date, not bookmarking date — the X API exposes the former and not the latter on these endpoints. If you bookmarked a 5-year-old tweet yesterday, the default 7-day window will miss it. Use a wider `--days` to capture older tweets you've recently bookmarked.

### 5. For each kept tweet — write, enrich-folder, or skip

Filename: `{output_path}/{tweet.id}.md`.

- **File does not exist:** write fresh with the shape below.
- **File exists, no `bookmark_folder_id` in its frontmatter, and this run is folder-scoped:** read frontmatter, set both `bookmark_folder: "{current_folder_name}"` and `bookmark_folder_id: "{current_folder_id}"`, write back. Touch nothing else (body, tags, created, status). This is the one allowed in-place mutation.
- **All other "file exists" cases:** **skip entirely**. The `## Notes` section may contain user edits; tweet content rarely changes upstream. In particular, do not rewrite `bookmark_folder` if the upstream folder was renamed — the ID is the join key; name drift is acceptable.

`bookmark_folder` and `bookmark_folder_id` are set **only** when the tweet was fetched via a specific-folder endpoint. The default all-bookmarks endpoint does not return folder membership; inferring it would be a lie.

`bookmark_folder_id` (not `bookmark_folder`) is the existence check for the mutation rule. Folder names can collide and rename upstream; the ID is the only stable signal that a file has already been folder-stamped.

If `--folders A,B` was specified and a tweet appears in both folder responses: the first folder query writes (or enriches) the file with its ID and name; the second is a skip (the file now has a `bookmark_folder_id` from the first). Input order determines the winner.

### 6. File shape (new files)

Frontmatter — minimal, telegram-style:

```yaml
---
type: raw
status: inbox
source: twitter
created: {YYYY-MM-DD of run}
tags: [raw, inbox, twitter, bookmark]
bookmark_folder: "{folder_name}"      # human-readable; OMIT both lines when fetched via /bookmarks default
bookmark_folder_id: "{folder_id}"     # stable join key; survives upstream renames and same-name collisions
---
```

Body:

```markdown
# Bookmark: @{author.username}

{tweet.text}

## Context
- https://x.com/{author.username}/status/{tweet.id}
- Posted: {tweet.created_at}
- Reply to: https://x.com/i/status/{reply_to_id}      # omit line if not a reply
- Quote of: https://x.com/i/status/{quote_of_id}      # omit line if not a quote
- Media: {url1}, {url2}                                # omit line if no media
- Related: [[Twitter]]

## Notes
```

`## Notes` is a deliberate empty space for the user or `expand-raw-ideas` to write into later.

### 7. Counts

- `new` — file did not exist; fresh write.
- `folder_added` — file existed, lacked `bookmark_folder_id`, and this folder-scoped run added the `bookmark_folder` / `bookmark_folder_id` pair.
- `unchanged` — file existed; skipped per idempotency rule.
- `error` — write or parse failure.

---

## Output

```
bookmark-fetcher complete
folder_scope:  {all | "<id1>,<id2>,..."}
new:           {N}
folder_added:  {N}
unchanged:     {N}
errors:        [list with tweet_id + reason]
files_written: [absolute paths, new + folder_added only]
```

---

## Resilience

- 401/403 → abort, print re-auth instruction.
- 429 → respect `x-rate-limit-reset` header, sleep, resume.
- Per-tweet write or parse failure → log, count, continue.
- Folder list (step 1b) returns 401/403 → abort entire run; folder-scoped mode requires this endpoint.
- Folder list returns 404 or empty `data` → abort folder-scoped run with "user has no bookmark folders". The default `/bookmarks` route is unaffected.
- Input `folder_id` not present in the resolved map → log "folder {id} not found in user's folder list", drop it from the endpoint set, continue with the rest.
- Folder-tweets endpoint returns 404 mid-run (e.g. folder deleted between steps 1b and 3) → log "folder {id} disappeared", continue with the next folder.

---

## Anti-patterns

- Do NOT call `curl`, `wget`, or SDK clients against api.x.com. Use `xurl`.
- Do NOT pass `tweet.fields`, `expansions`, `user.fields`, `media.fields`, `max_results`, or `pagination_token` to `/2/users/{user_id}/bookmarks/folders/{folder_id}` — that endpoint returns a flat ID list and silently ignores or errors on these params. Hydrate via `/2/tweets?ids=...` instead (step 3B).
- Do NOT use the `/folders/{folder_id}/tweets` URL shape — it 404s on the live API. The correct path is `/folders/{folder_id}` (no `/tweets` suffix).
- Do NOT create per-folder subdirectories under `{output_path}` — bookmarks are flat by design.
- Do NOT set `bookmark_folder` or `bookmark_folder_id` on tweets fetched from the default all-bookmarks endpoint; the API does not return folder membership there.
- Do NOT write `bookmark_folder` without `bookmark_folder_id` (or vice versa). Names collide and rename; IDs don't. They travel as a pair.
- Do NOT use `bookmark_folder` (the name) as the existence check in the mutation rule. Use `bookmark_folder_id`. Same-name folders and upstream renames will silently corrupt your idempotency otherwise.
- Do NOT rewrite an existing `bookmark_folder` to chase upstream renames. The ID is the source of truth; let names drift.
- Do NOT touch existing files except for the one allowed mutation (adding the missing `bookmark_folder` / `bookmark_folder_id` pair during a folder-scoped run). The `## Notes` section may contain user edits.
- Do NOT delete files for unbookmarked-upstream tweets — non-destructive archive.
- Do NOT short-circuit pagination based on a single tweet's date; bookmarks come in bookmarking order, not creation order.
- Do NOT report success without verifying the file actually exists on disk after each write. `Write` errors must be caught and counted as `error`, not silently swallowed.
