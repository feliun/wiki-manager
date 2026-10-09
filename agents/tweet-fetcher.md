---
name: tweet-fetcher
description: >
  Fetches the user's own X posts since a given timestamp via the `xurl`
  CLI and writes one file per tweet to {output_path}/{tweet_id}.md
  (flat). Idempotent — re-runs are skip-if-exists. Telegram-style
  minimal frontmatter (`type`, `status`, `source`, `created`, `tags`);
  all other metadata lives in the body under `## Context`.
subagent_type: general-purpose
---

# Agent: Tweet Fetcher

**Role:** Pull the user's own tweets since `{since}` and persist them flat
to `{output_path}/{tweet_id}.md`. Use `xurl` for **every** X API call —
never `curl`, `wget`, or library clients. `xurl` is the only client
configured with the OAuth2 user-context auth required for the
authenticated-user endpoints used here.

**Inputs (passed by `/pull-tweets`):**

- `since` — RFC 3339 UTC, e.g. `2026-04-24T00:00:00Z`
- `username` — X handle, no `@`
- `output_path` — absolute directory (must exist or be creatable)
- `vault_root` — absolute path

---

## Bootstrap

1. Verify `xurl` is on PATH:
   ```bash
   command -v xurl >/dev/null 2>&1 || echo MISSING
   ```
   If missing: emit `xurl not found — install via 'brew install mangopdf/utils/xurl' (see https://github.com/mangopdf/xurl), then run 'xurl auth login' with an X dev portal app whose callback URL is http://127.0.0.1:8080/callback`, abort.

2. Create `{output_path}` if absent:
   ```bash
   mkdir -p {output_path}
   ```

---

## Process

### 1. Resolve user ID

```bash
xurl "/2/users/by/username/{username}"
```

Extract `data.id` → `{user_id}`. Cache for the run. On 401/403, abort
with `re-run \`xurl auth oauth2\``.

### 2. Fetch tweets, paginated

Loop until `meta.next_token` is absent:

```bash
xurl "/2/users/{user_id}/tweets?max_results=100&start_time={since}&tweet.fields=created_at,referenced_tweets,attachments,entities,note_tweet&expansions=attachments.media_keys,referenced_tweets.id,referenced_tweets.id.author_id&media.fields=url,preview_image_url,type&user.fields=username"
```

Append `&pagination_token={next_token}` on subsequent pages. Cap at 50 pages as a safety bound; if hit, log and stop with `pagination cap reached`.

> **`note_tweet` is REQUIRED in `tweet.fields` — do not drop it.** Without it the X
> API silently truncates long-form posts at 280 characters, mid-sentence, with no
> ellipsis, no flag and no error. Observed 2026-08-18: 7 of 49 tweets in a 12-day
> window were affected, one losing 330 of 605 characters. The truncated text is
> well-formed and reads as a complete short tweet, so nothing downstream can detect
> it and the archive silently loses content. Always read the body from
> `note_tweet.text` when it is present and longer than `text`.


### 3. For each tweet — write or skip

Filename: `{output_path}/{tweet.id}.md`.

- **File does not exist:** write with the shape below.
- **File exists:** **skip entirely**. Do not read, do not touch, do not merge. Tweet content rarely changes upstream, and the file may contain user edits under `## Notes`. Re-runs are a no-op on existing files. (If you genuinely need to refresh a captured tweet, delete the file and re-run.)

### 4. File shape (new files)

Frontmatter — minimal, telegram-style:

```yaml
---
type: raw
source: twitter
created: {YYYY-MM-DD of run}
tags: [raw, inbox, twitter, tweet]
---
```

Body:

```markdown
# Tweet

{tweet.text}

## Context
- https://x.com/{username}/status/{tweet.id}
- Posted: {tweet.created_at}
- Reply to: https://x.com/i/status/{reply_to_id}      # omit line if not a reply
- Quote of: https://x.com/i/status/{quote_of_id}      # omit line if not a quote
- Media: {url1}, {url2}                                # omit line if no media
- Related: [[Twitter]]

## Notes
```

`## Notes` is a deliberate empty space the user (or `expand-raw-ideas`) writes into later.

### 5. Counts

Track `new`, `unchanged`, `error`:

- `new` — file did not exist; fresh write.
- `unchanged` — file existed; skipped per idempotency rule.
- `error` — write or parse failure.

---

## Output

```
tweet-fetcher complete
new:       {N}
unchanged: {N}
errors:    [list with tweet_id + reason]
files_written: [absolute paths, new only]
```

---

## Resilience

- 401/403 → abort, print re-auth instruction.
- 429 → respect `x-rate-limit-reset` header, sleep, resume.
- Per-tweet write or parse failure → log to `errors`, increment `error` count, continue.

---

## Anti-patterns

- Do NOT call `curl`, `wget`, `httpie`, or SDK clients against api.x.com. Use `xurl`.
- Do NOT write to subdirectories of `{output_path}` — output is flat.
- Do NOT touch existing files. Re-runs are skip-if-exists. The `## Notes` section may contain user edits.
- Do NOT delete files for upstream-deleted tweets — the raw archive is non-destructive.
- Do NOT promote parent-tweet context to standalone files — that's a downstream concern for `expand-raw-ideas`.
- Do NOT report success without verifying the file actually exists on disk after each write. `Write` errors must be caught and counted as `error`, not silently swallowed.
