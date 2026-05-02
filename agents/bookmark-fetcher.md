---
name: bookmark-fetcher
description: >
  Fetches the user's X bookmarks since a given timestamp via the `xurl`
  CLI and writes one file per tweet to {output_path}/{tweet_id}.md
  (flat — no per-folder subdirectories). Defaults to all bookmarks; can
  scope to one or more folder IDs. Idempotent — re-runs are
  skip-if-exists, with one allowed in-place mutation: a folder-scoped
  re-run may add `bookmark_folder` to a file that lacked it.
  Telegram-style minimal frontmatter; all other metadata lives in the
  body under `## Context`.
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

### 2. Determine endpoint set

- `folder_ids` empty/null → single endpoint: `/2/users/{user_id}/bookmarks`
- `folder_ids` non-empty → one call sequence per folder ID: `/2/users/{user_id}/bookmarks/folders/{folder_id}/tweets`

### 3. Fetch each endpoint, paginated

```bash
xurl "{endpoint}?max_results=100&tweet.fields=created_at,author_id,attachments,entities,referenced_tweets&expansions=author_id,attachments.media_keys,referenced_tweets.id,referenced_tweets.id.author_id&user.fields=username&media.fields=url,preview_image_url,type"
```

Loop on `meta.next_token` (append `&pagination_token={next_token}`). Cap at 50 pages per endpoint as a safety bound.

### 4. Filter by `since` — client-side

The bookmarks endpoints accept no `start_time` parameter and return tweets in **bookmarking order**, not tweet-creation order. Filtering happens client-side:

```
keep tweet iff tweet.created_at >= since
```

**Do not short-circuit pagination.** A page may interleave old and new tweets in arbitrary order (you might bookmark a 2-year-old tweet today, putting it at the top of page 1). Walk every page returned, filter on each, until `next_token` is absent or the safety cap is hit.

> Semantic note: "past 7 days" filters by tweet creation date, not bookmarking date — the X API exposes the former and not the latter on these endpoints. If you bookmarked a 5-year-old tweet yesterday, the default 7-day window will miss it. Use a wider `--days` to capture older tweets you've recently bookmarked.

### 5. For each kept tweet — write, enrich-folder, or skip

Filename: `{output_path}/{tweet.id}.md`.

- **File does not exist:** write fresh with the shape below.
- **File exists, no `bookmark_folder` in its frontmatter, and this run is folder-scoped:** read frontmatter, set `bookmark_folder: {current_folder_id}`, write back. Touch nothing else (body, tags, created, status). This is the one allowed in-place mutation.
- **All other "file exists" cases:** **skip entirely**. The `## Notes` section may contain user edits; tweet content rarely changes upstream.

`bookmark_folder` is set **only** when the tweet was fetched via a specific-folder endpoint. The default all-bookmarks endpoint does not return folder membership; inferring it would be a lie.

If `--folders A,B` was specified and a tweet appears in both folder responses: the first folder query writes (or enriches) the file with its ID; the second is a skip (the file now has a `bookmark_folder` from the first). Input order determines the winner.

### 6. File shape (new files)

Frontmatter — minimal, telegram-style:

```yaml
---
type: raw
status: inbox
source: twitter
created: {YYYY-MM-DD of run}
tags: [raw, inbox, twitter, bookmark]
bookmark_folder: "{folder_id}"   # OMIT this line entirely when fetched via /bookmarks default
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
- `folder_added` — file existed, lacked `bookmark_folder`, and this folder-scoped run added it.
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
- Folder ID returns 404 → log "folder {id} not found", continue with the next folder.

---

## Anti-patterns

- Do NOT call `curl`, `wget`, or SDK clients against api.x.com. Use `xurl`.
- Do NOT create per-folder subdirectories under `{output_path}` — bookmarks are flat by design.
- Do NOT set `bookmark_folder` on tweets fetched from the default all-bookmarks endpoint; the API does not return folder membership there.
- Do NOT touch existing files except for the one allowed mutation (adding a missing `bookmark_folder` during a folder-scoped run). The `## Notes` section may contain user edits.
- Do NOT delete files for unbookmarked-upstream tweets — non-destructive archive.
- Do NOT short-circuit pagination based on a single tweet's date; bookmarks come in bookmarking order, not creation order.
- Do NOT report success without verifying the file actually exists on disk after each write. `Write` errors must be caught and counted as `error`, not silently swallowed.
