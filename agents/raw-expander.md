---
name: raw-expander
description: >
  Expand all raw/ ideas into wiki notes. Thin loop: lists raw files
  recursively (including any source-grouped subfolders such as
  `telegram/`, `notes/`, `twitter/`), filters by status, and dispatches
  each one to the `expand-raw-ideas` skill, which in turn delegates the
  write to `create-note`.
subagent_type: general-purpose
---

# Agent: Raw Expander

**Role:** List all `.md` files in `{raw_folder}` **recursively** (walk all
subfolders — captures may be grouped by source under `telegram/`,
`notes/`, `twitter/`, etc.), dispatch each `status: inbox` file to the
`expand-raw-ideas` skill, aggregate results.

**Symlink-aware traversal:** source-grouped subfolders may be symlinks
(e.g. a `telegram/` subfolder pointing at a cloud-synced GDrive folder
so a mobile capture bot can write into it). The walk **must follow
symlinks**. On macOS/BSD this means: prefer `find -L {raw_folder} -name
'*.md'` over `find {raw_folder} -name '*.md'`, and `grep -R` (uppercase)
over `grep -r` (lowercase). Default flags will silently skip symlinked
subfolders and miss real captures.

**Inputs:** the resolved configs from the `manifest-resolver` —
`vault-paths`, `note-types`, `tag-policy`, `concept-hubs`, `linking-rules`,
`naming-convention`. The host command (`/ingest`, or any other command that invokes this agent) resolves them and passes the absolute paths in.

This agent does **not** own any policy. All policy decisions happen inside
`expand-raw-ideas` and `create-note`. Keep this loop thin.

---

## Bootstrap

1. Load the resolved `vault-paths` config. If missing, abort with a clear
   error.
2. Resolve `raw_folder` and (if set) `vault_root`. Treat `raw_folder` as
   relative to `vault_root` when set, else `$WORKSPACE`.
3. **Probe the `obsidian` CLI once.** Run via `Bash`:
   ```bash
   command -v obsidian >/dev/null 2>&1 && obsidian list-vaults >/dev/null 2>&1 && echo OK || echo MISSING
   ```
   - `OK` → cache the signal and rely on `obsidian create`/`obsidian search`
     for all writes and searches downstream in the chain.
   - `MISSING` → emit a single warning (`"obsidian CLI unreachable; writes
     will use Write fallback and Obsidian's index won't see new notes until
     reload"`) and continue. Do **not** abort — the loop still produces valid
     notes; the user just needs to reload the vault to surface them.
4. Pass the remaining configs through to `expand-raw-ideas` unchanged — the
   skill chain re-resolves what it needs via `manifest-resolver`.

---

## Loop

For each `.md` file under `{raw_folder}` (recursively across all
subfolders) **sequentially** (never parallel — each expansion may affect
dedup state for the next):

1. Read the file's frontmatter. Skip if `status` is not `inbox`.

2. Invoke the `expand-raw-ideas` skill with the absolute path of the raw
   file. The skill:
   - extracts source content (URL via `defuddle`, fallback to `WebFetch`,
     fallback to raw text),
   - chooses a `type_hint`,
   - dedup-checks against `{wiki_folder}`,
   - rewrites the body,
   - delegates to `create-note` for the actual write, hub link, tags,
     filename, file write, raw-file backlink, and index registration.

3. Capture the result:
   - On `created`: count as `expanded`.
   - On dedup-hit (skill returned without calling `create-note`): count as
     `skipped (duplicate)`.
   - On error: log the error, count as `error`, continue to the next file.

4. Track all `created` paths, modified raw files, and the index file path
   from the skill's return value.

---

## Output

When the loop completes, print:

```
raw-expander complete
expanded: {N}
skipped:  {N} (already processed: {N}, duplicates: {N})
files_created: [list of wiki note paths]
files_modified: [list of raw file paths + index file if updated]
errors: [list of any errors encountered]
```

---

## Resilience

- If a single raw file fails, log the error and continue with the next.
- Never delete raw files — `create-note` handles backlink + status update.
- Process files **sequentially**, never in parallel.

---

## Anti-patterns

- Do NOT re-implement frontmatter, hub linking, tag selection, filename
  rules, or index registration in this agent — those live in `create-note`.
- Do NOT parallelize the loop.
- Do NOT call `create-note` directly from this agent — go through
  `expand-raw-ideas` so dedup and rewrite happen first.
- Do NOT write to files outside the resolved vault.
