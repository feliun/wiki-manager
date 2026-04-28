---
type: reference
status: active
created: 17-01-2026
tags: [skill, wiki-manager, obsidian]
---
# Skill: Expand Raw Ideas

Purpose:
Take a single raw, unstructured capture and prepare it for write — extract
source content, choose the type, dedup against the vault, rewrite the idea — then **delegate the actual write to `create-note`**, which owns frontmatter, hub linking, tags, filename, file write, raw-file backlink, and indexing.

When to use:
- A note has `status: inbox` (or `type: raw`) and needs expansion.
- The user explicitly asks to "expand" or "develop" an idea.
- Called from `/ingest` or the `raw-expander` agent for a single file.

---

## Dependencies

- **`manifest-resolver` skill** — invoke first to bind `vault-paths` (for the
  raw file location and dedup search). `create-note` will resolve the rest.
- **`obsidian:defuddle` skill** — when the raw note contains a URL. Use
  `defuddle parse <url> --md` for clean source extraction.
- **`obsidian` Bash CLI** — for the dedup search across the vault. The
  `obsidian:obsidian-cli` skill documents the syntax; the actual search is a
  plain `Bash` invocation. Fall back to `grep`/`Glob` over `{wiki_folder}` only
  when the probe (`command -v obsidian` + `obsidian list-vaults`) fails.
- **`create-note` skill** — owns the write pipeline. **Always delegate** —
  never write the wiki note directly from this skill.

---

## Process

1. **Resolve config.** Invoke `manifest-resolver` for `wiki-manager` and bind
   `vault-paths`.

2. **Read the raw file** at the given path. Skip if `status` is not `inbox`
   (already processed).

3. **Extract source content.** Identify the core idea.
   - If the raw file contains a URL, run `defuddle parse <url> --md` for clean content extraction.
   - Fall back to `WebFetch` on failure.
   - If both fail, use the raw text only.

4. **Determine the type hint.** Match capture cues against the keys of
   `note-types.types` (e.g. "To buy:" → `to-buy`, "To read:" → `to-read`,
   book quotes → `book`). If ambiguous, leave the hint unset and let
   `create-note` resolve it.

5. **Dedup check.** Run `obsidian search query='path:{wiki_folder} <terms>'`
   via `Bash` (the `obsidian:obsidian-cli` skill is documentation, not a
   runtime tool). If the pre-flight probe failed, fall back to
   `grep -rl '<terms>' {wiki_folder}`. If a clear duplicate exists:
   - Append an `## Expanded` section to the raw file with a wikilink to the
     existing note.
   - Set the raw file's `status` to `done`.
   - **Do not call `create-note`. Stop here.**

5. **Rewrite the idea** clearly in your own words. Max 400 words. High signal, no filler. Do **not** invent facts — only expand what is in the raw idea or its linked source.

6. **Delegate to `create-note`** with:
   - `body`: the rewritten idea (no frontmatter).
   - `type_hint`: from step 4 (omit if unresolved).
   - `source_url`: the URL from step 3, when present.
   - `source_raw_file`: the absolute path of the raw file (triggers the
     `## Expanded` backlink and `status: done` update).
   - `created_date`: from the raw file's `created` field, else today.
   - `target_root`: `wiki` (default — omit).

8. **Return the result** of `create-note` to the caller (path, type, indexed,
   warnings).

---

## Output

The structured result returned by `create-note`. No additional formatting.

---

## Anti-patterns

- Do NOT invent facts — only expand what's present in the raw idea or its linked source.
- Do NOT overextend beyond the idea's intent.
- Do NOT write the wiki note directly — always delegate to `create-note`.
- Do NOT delete raw files — `create-note` handles backlink + status update.
- Do NOT skip the dedup check; duplicates pollute the index.
