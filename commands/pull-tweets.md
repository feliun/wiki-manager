---
name: wiki-manager:pull-tweets
description: >
  Fetch your X/Twitter posts and bookmarks into raw/twitter/ for the
  ingest pipeline. Defaults to the past 7 days. Idempotent: each tweet
  is filed under its immutable {tweet_id}.md, so re-runs are skip-if-exists
  and never disturb user edits or downstream-set fields.
---

# Pull Tweets

Pull your own posts and your bookmarked tweets via the `xurl` CLI and
persist them flat. Output paths come from `twitter.yaml`:

- own posts:  `{vault_root}/{tweets.path}{tweet_id}.md`
- bookmarks:  `{vault_root}/{bookmarks.path}{tweet_id}.md`

Tweets and bookmarks are treated as **independent streams** with separate
config blocks (`tweets:` and `bookmarks:` in `twitter.yaml`), separate
output paths, separate lifecycles, and separate lookback windows.

The asymmetry is intentional. **Own posts live at vault root** as a
finished authored archive — they're not raw captures awaiting expansion,
they're already-published thoughts you're keeping a local copy of.
**Bookmarks live under `raw/`** and are real raw captures: external
content you saved with the intent of processing it later. Only the
bookmarks land in the `raw-expander` pipeline; tweets sit outside it by
design.

**X API access tool: `xurl`** (OAuth2 user-context, registered as
`prod-app`). Never substitute `curl` + bearer-token — bookmark endpoints
require user context that only `xurl` is configured for. If `xurl` is
absent or auth fails, abort with a clear error rather than partial-fetching.

---

## Args

- `--days N` — lookback window in days. Applies to **both** streams when set. When omitted, each stream falls back to its own `window_days` from `twitter.yaml` (`tweets.window_days` and `bookmarks.window_days`, both shipping at 7).
- `--since YYYY-MM-DD` — explicit start date (overrides `--days`).
- `--tweets-only` — skip bookmarks.
- `--bookmarks-only` — skip own tweets.
- `--folder <id>` — scope bookmarks to a single folder; also populates `bookmark_folder` frontmatter on captured notes.
- `--folders <id1,id2,...>` — scope bookmarks to multiple folders. Composes with `--bookmarks-only`.

Find folder IDs with one xurl call:

```bash
xurl "/2/users/me/bookmarks/folders"
```

Returns `data[].id` and `data[].name`. Without a folder flag, the
default-bookmarks endpoint returns every bookmark you have, so the
`bookmark_folder` field is omitted (the API does not return folder
membership on the all-bookmarks endpoint).

---

## Process

### 1. Resolve config

Invoke the `manifest-resolver` skill to load `vault-paths` and `twitter`.
From the resolved values capture:

- `vault_root` — absolute path (from vault-paths)
- `username` — X handle, no `@` (shared, top-level in twitter.yaml)
- `tweets.path`, `tweets.window_days`
- `bookmarks.path`, `bookmarks.window_days`

Both `path` values are relative to `vault_root` and have a trailing slash.

### 2. Compute the `since` boundaries

Per-stream — each stream uses its own `window_days` default unless overridden by CLI:

- `since_tweets`:    `--since` > `--days` > `tweets.window_days`
- `since_bookmarks`: `--since` > `--days` > `bookmarks.window_days`

When `--days N` or `--since YYYY-MM-DD` is passed on the CLI, **both streams use the same value** — the per-stream defaults only apply when neither flag is given. Convert to RFC 3339 UTC at midnight: `YYYY-MM-DDT00:00:00Z`.

### 3. Determine fetch scopes

- Tweets enabled unless `--bookmarks-only`.
- Bookmarks enabled unless `--tweets-only`.
- Bookmark folder scope: parse `--folder` / `--folders` into a list; absent → `null` (= all bookmarks).

If both `--tweets-only` and `--bookmarks-only` are passed, abort with a usage error.

### 4. Dispatch fetcher agents in parallel

In a **single message** (not sequential turns), spawn:

- `tweet-fetcher` with `{since: since_tweets, username, output_path: {vault_root}/{tweets.path}, vault_root}` — only if tweets enabled.
- `bookmark-fetcher` with `{since: since_bookmarks, folder_ids, output_path: {vault_root}/{bookmarks.path}, vault_root}` — only if bookmarks enabled.

Parallel dispatch matters: a single-day window pulls cleanly in seconds,
but `--days 365` will hit pagination on both endpoints and benefits from
true concurrency.

### 5. Aggregate

Merge the two agents' counts (`new`, `folder_added`, `unchanged`, `errors`)
and the lists of files written.

---

## File shape

Both fetchers write the **telegram-style minimal frontmatter** convention. The two streams diverge in two places: `status` (only on bookmarks, since only bookmarks enter the ingest pipeline) and `bookmark_folder` (bookmarks only, and only on folder-scoped runs). Full body shape lives in each fetcher's spec.

**Tweets** (own posts — no `status`, no folder concept):

```yaml
---
type: raw
source: twitter
created: {YYYY-MM-DD of run}
tags: [raw, inbox, twitter, tweet]
---
```

**Bookmarks** (saved tweets — `status: inbox` for ingest, optional folder):

```yaml
---
type: raw
status: inbox
source: twitter
created: {YYYY-MM-DD of run}
tags: [raw, inbox, twitter, bookmark]
bookmark_folder: "{folder_id}"   # only when fetched via specific folder
---
```

All other metadata (URL, author, posted-at, media, reply/quote parents) lives in the body under `## Context`. The body ends with an empty `## Notes` heading reserved for user thoughts during expansion.

---

## Idempotency contract

Both fetchers obey the same rules:

- **Filename:** `{tweet_id}.md`. No date prefix, no slugified title.
- **Existing file → skip.** Do not read, do not merge, do not touch. The `## Notes` body section may contain user edits, and the body above it rarely needs refreshing (X's edit window is narrow). Re-runs are a no-op on existing files.
- **One narrow exception** (bookmarks only): if `--folder` / `--folders` is in play and an existing file lacks `bookmark_folder` in its frontmatter, the bookmark-fetcher may add that single field — touching nothing else. This is the only allowed in-place mutation across the whole pipeline.
- **No deletes.** A tweet that's been deleted upstream stays in the vault — the raw archive is non-destructive.
- **Concurrent folder hits** (`--folders A,B` where a tweet sits in both): first folder query wins (writes the file or adds `bookmark_folder`); the second is a skip. Input order is the tiebreak.

---

## Resilience

- `xurl` missing or 401/403: abort. Print `re-run \`xurl auth oauth2\`` and exit non-zero.
- One fetcher fails, other succeeds: report both, exit zero. Partial progress beats none.
- Pagination cursor stuck (no progress for 3 consecutive calls): bail per-fetcher with a clear error and continue with whatever was collected.
- Per-tweet errors (write failure, malformed response): log, count, continue.

---

## Report

```
PULL TWEETS — DD-MM-YYYY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Window:     {since-date} → today
Tweets:     {N} new, {N} unchanged
Bookmarks:  {N} new, {N} folder_added, {N} unchanged   (scope: all | folder:{ids})
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Files written:  [list of absolute paths]
Errors:         [list, if any]
```
