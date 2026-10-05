---
description: "Standalone ingest processing — expands all raw captures into structured wiki notes."
---

# Ingest

Expand every raw capture under the configured `raw_folder` — **including
any source-grouped subfolders** (e.g. `telegram/`, `notes/`, `twitter/`)
— into a structured wiki note that complies with the active wiki-manager
policies.

---

## Process

1. **Resolve config.** Invoke the `manifest-resolver` skill to load
   `vault-paths`, `note-types`, `tag-policy`, `concept-hubs`, `linking-rules`,
   and `naming-convention`.
2. **Filter unprocessed files.** Use `obsidian:obsidian-cli` to query the vault
   index directly:
   ```bash
   obsidian search query='path:{raw_folder} [type:raw] -[status:done] -[status:skipped]'
   ```
   Substituting `{raw_folder}` with the resolved value **literally,
   including any trailing slash**. The slash matters: Obsidian's `path:`
   operator does substring matching, so `path:raw/` is folder-scoped
   while `path:raw` is a loose substring match that will also pick up
   files like `system/templates/raw.md` (the raw-capture template,
   which legitimately has `type: raw` and `status: inbox`). Do not
   normalize or strip the slash from the config value — preserve it as
   written in `vault-paths.yaml`.

   > **Exclude `status: skipped`, not just `status: done`.** A `skipped`
   > capture is one a *previous* ingest run examined and deliberately
   > declined to expand — it is processed, just not expanded. Filtering
   > only on `-[status:done]` re-surfaces every past decline on every
   > run, which re-litigates a settled decision and invites duplicate
   > wiki notes. Observed 2026-08-11: the `-[status:done]`-only filter
   > returned 7 files, of which 6 were `status: skipped` bookmarks from
   > an earlier run and exactly 1 (`status: inbox`) was genuinely new.
   > Only `inbox` (and any other non-terminal status in
   > `note-types.yaml`) is unprocessed.

   **An empty result is UNPROVEN, not "nothing to do."** Never report
   "no files to process" on the strength of `obsidian search` alone.
   The CLI exits **0** with empty output when the index is unavailable,
   which is byte-for-byte identical to a genuine no-match — and the
   binary being healthy and Obsidian being *running* do not imply the
   index is answering. Observed 2026-08-11: every query returned empty
   with exit 0 (including `query='Linear'`, which had matches) while
   `obsidian read path=` worked fine; a capture sat unprocessed and the
   run would have reported a clean "no files to process."

   So: **on an empty search result, always run the filesystem fallback
   and reconcile.** Only when *both* agree on zero may you report
   "no files to process". If they disagree, trust the filesystem and
   note that the index is stale.

   **Filesystem fallback** (also the mandatory cross-check above):
   ```bash
   # candidates = raw captures not yet terminal
   find -L {raw_folder} -name '*.md' -print0 | while IFS= read -r -d '' f; do
     grep -qE '^status: (done|skipped)' "$f" </dev/null || echo "$f"
   done
   ```
   The directory walk MUST be `find -L` — **never `grep -R`**. Both
   terminal statuses are excluded in one pass: `done` and `skipped`.
   `</dev/null` keeps the loop from having its stdin eaten (see the
   `obsidian` CLI stdin hazard — it applies to any external command in
   a `while read`/`for` loop that reads stdin), and `-print0` with
   `read -d ''` survives spaces in capture filenames, which the older
   `for f in $(...)` form split into fragments.

   > **Why not `grep -R`.** BSD grep's `-R` follows only the symlinks
   > given to it as explicit command-line arguments — it does **not**
   > descend through a symlinked directory encountered during the walk.
   > That is the same contract as `find` *without* `-L`, not the
   > symlink-following behaviour the flag's name suggests. Measured on
   > macOS (BSD grep 2.6.0-FreeBSD) against a `raw/` holding 234
   > captures, of which 118 sat behind a `raw/telegram` symlink to a
   > sync folder:
   >
   > | invocation | files seen |
   > |---|---|
   > | `grep -Rl '' --include='*.md' raw/` | 116 — **telegram missing** |
   > | `find raw -name '*.md'` (no `-L`) | 116 — identical blind spot |
   > | `find -L raw -name '*.md'` | **234 — correct** |
   > | `grep -Rl '' --include='*.md' raw/telegram/` | 118 — follows an *explicit* arg |
   > | `grep -Rl '' --include='*.md' raw/telegram` | **0** — no trailing slash, read as a file |
   >
   > `raw/telegram/` is exactly where mobile captures land, so this
   > silently drops the most active stream — and it drops it to a clean
   > exit 0, indistinguishable from a genuine empty queue. Observed
   > 2026-10-05: the index was mute *and* `grep -R` was blind, both
   > returned zero, and the run would have reported "no files to
   > process" while a real `status: inbox` capture sat in
   > `raw/telegram/`. Two detectors agreeing on zero is not
   > confirmation when they share a blind spot.
3. **Expand each file.** For each unprocessed file, apply the
   `expand-raw-ideas` skill — follow ALL rules completely.

---

## Resilience

- If a file cannot be processed (ambiguous, empty, broken): skip it, report it, continue with the next.
- Process files one at a time — each expansion may affect vault state for dedup checks.

---

## Report

After processing, present:

```
INGEST PROCESSING — DD-MM-YYYY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Processed: X files
Skipped:   Y files (with reasons)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Created in wiki: [list with types]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
