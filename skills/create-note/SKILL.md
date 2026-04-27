---
name: create-note
description: "Use whenever the user asks to create, save, write, or persist a new note in the vault — ad-hoc in conversation or from any wiki-manager command or agent. Owns the full write pipeline: type resolution, frontmatter, Concept Hub linking, tag selection, filename, file write, raw-source backlink, and index registration. Other skills (expand-raw-ideas, feed, raw-expander) delegate the write step to this skill rather than rolling their own."
type: reference
status: active
created: 27-04-2026
tags:
  - skill
  - wiki-manager
  - obsidian
---
# Skill: Create Note

Purpose:
Single canonical pipeline for writing a new note into the vault. All policy
enforcement (types, statuses, tags, hub linking, naming, indexing) lives here so callers stay thin and consistent.

When to use:
- The user asks to create / save / write / persist a new note (in any phrasing, in any context).
- A higher-level skill or command has produced note content and needs it
  written to the vault: `expand-raw-ideas`, `/feed`, the `raw-expander` agent, or any future workflow.

When NOT to use:
- Editing an existing note → use `obsidian:obsidian-cli` directly.
- Bulk migrations or rebuilds → call this skill once per note, sequentially.
- Pure indexing operations → use `wiki-indexer` directly.

---

## Dependencies

- **`manifest-resolver` skill** — resolve `vault-paths`, `note-types`,
  `tag-policy`, `concept-hubs`, `linking-rules`, `naming-convention`. Required.
- **`obsidian:obsidian-markdown` skill** — frontmatter and wikilink syntax
  reference. Invoke before composing the note.
- **`obsidian:obsidian-cli` skill** — primary write path; also used for vault
  searches (existing-file checks, hub matching). Falls back to the `Write` tool
  if unavailable.
- **`wiki-indexer` skill** — invoked at the end (Mode A) for wiki-rooted notes.

---

## Inputs

The caller passes a structured payload. Only `body` is required.

| Field | Required | Purpose |
|---|---|---|
| `body` | yes | Note content, already cleaned/rewritten. No frontmatter. |
| `type_hint` | no | Caller's guess at the type (e.g. `idea`, `book`, `to-buy`, `reference`). Validated against `note-types`. |
| `title_hint` | no | Suggested title without date prefix or extension. |
| `source_url` | no | Origin URL — captured into frontmatter as `source`. |
| `source_raw_file` | no | Absolute path of a raw capture this note expands. Triggers backlink + raw-status update. |
| `extra_tags` | no | Caller-supplied tags merged with inferred tags (still validated against `tag-policy`). |
| `target_root` | no | `wiki` (default) or `outputs`. Selects rooting strategy. |
| `target_subfolder_override` | no | Explicit subfolder under the chosen root. **Required when `target_root=outputs`.** |
| `created_date` | no | `DD-MM-YYYY`. Defaults to today. |

When the user invokes this skill ad-hoc ("save this as a note about X"), infer the inputs from the conversation and surface assumptions before writing.

---

## Process

1. **Resolve config.** Invoke `manifest-resolver` for `wiki-manager`. Bind
   each resolved YAML: `vault-paths`, `note-types`, `tag-policy`,
   `concept-hubs`, `linking-rules`, `naming-convention`. Abort if
   `vault-paths` is missing.

2. **Resolve type.**
   - If `type_hint` is a key in `note-types.types`, accept it.
   - Else infer from `body` against the keys in `note-types.types`.
   - If still ambiguous, fall back to the first type defined in
     `note-types.types` (canonical default — typically `note`). Surface the
     decision when the request was ad-hoc.

3. **Resolve initial status** from `note-types.types[type].initial_status`.

4. **Resolve title.**
   - Use `title_hint` if provided; else extract a clean title from `body`
     (first heading, or first sentence trimmed).
   - Cap at `naming-convention.max_title_length`.
   - Apply `naming-convention.word_separator`.
   - Preserve accents per `naming-convention.preserve_accents`.

5. **Build filename.**
   - When `type` is in `naming-convention.timeless_types` → no date prefix.
   - Else prefix with `created_date` formatted per
     `naming-convention.dated_format` (default `YYYY-MM-DD`).
   - Append `.md`.

6. **Resolve target path.**
   - `target_root=outputs`:
     `{vault-paths.outputs_folder}/{target_subfolder_override}/{filename}`.
     `target_subfolder_override` MUST be set; abort otherwise. If
     `vault-paths.outputs_subfolders` is non-empty, warn when the override is not in the list (continue anyway).
   - `target_root=wiki` (default):`{vault-paths.wiki_folder}/{type}/{filename}`.
   - Create the subfolder if it doesn't exist.
   - If a file already exists at the target path, **stop and ask the user
     before overwriting**. Never silently clobber.

7. **Resolve tags.**
   - Start from `extra_tags`, then add 2–3 tags inferred from `body`.
   - Keep only tags present in`tag-policy.allowed_domain_tags ∪ allowed_life_tags ∪ allowed_format_tags`.
   - Reject any tag in `tag-policy.banned_tags`; surface the `use_instead`
     guidance.
   - Cap at 4 tags total.
   - When `linking-rules.prefer_wikilinks_over_tags` is true and a Concept Hub matches the topic, drop the corresponding tag in favor of the wikilink added in step 8.

8. **Resolve hub links.** When `linking-rules.require_moc_link` is true and
   `concept-hubs.hubs` is non-empty:
   - Pick at least one hub from `concept-hubs.hubs` whose topic matches the note. Prefer the closest semantic match; multiple hubs are allowed.
   - When `linking-rules.use_related_section` is true → append a `## Related`section at the end of `body` containing the hub wikilinks.
   - Else inline the wikilinks at a natural position in `body`.
   - When `concept-hubs.hubs` is empty: emit a warning, continue without a hub link. (Hard requirement degrades to soft warning.)

9. **Compose frontmatter.** Use proper Obsidian property types (per
   `obsidian:obsidian-markdown`):
   - `type` and `status` as text (lowercase).
   - `tags` as a YAML list.
   - `created` in `DD-MM-YYYY`.
   - `source` as `"{source_url}"` when present.
   - **Newline between the last field and the closing `---`.**

10. **Compose final note.** Frontmatter + body. Wikilinks for all internal
    references — never plain markdown links to vault notes. Callouts
    (`> [!tip]`, `> [!example]`, `> [!quote]`) where they add clarity, but do
    **not** invent content not present in `body`.

11. **Write the file.** Invoke `obsidian:obsidian-cli`:
    ```
    obsidian create path="{absolute path}" content="{composed note}" silent
    ```
    - `silent` so the file does not open in Obsidian.
    - Fall back to the `Write` tool if Obsidian CLI is unavailable; flag the
      degradation in `warnings`.

12. **Backlink the source raw file** (only when `source_raw_file` is set):
    - Append an `## Expanded` section to the raw file with a wikilink to the
      new note.
    - Set the raw file's `status` to `done`.
    - **Never delete the raw file.**

13. **Register in the index.** When `target_root=wiki`, invoke `wiki-indexer`
    (Mode A) with `filename`, `type`, and a one-line summary derived from the body's first sentence. `wiki-indexer` is the authority on which types are indexed; pass everything through and let it filter.
    - When `target_root=outputs`: skip indexing (these are outputs, not wiki notes).

---

## Output

Return a structured result to the caller:

```
created: {absolute path}
type: {type}
status: {status}
tags: [...]
hub_links: [...]
indexed: true|false
backlinked_raw: {raw file path or null}
warnings: [...]
```

When invoked ad-hoc by the user, also print a one-line confirmation:

```
NOTE CREATED — {absolute path} (type: {type}, indexed: {true|false})
```

---

## Anti-patterns

- Do NOT invent content beyond `body` — callers own the rewrite.
- Do NOT overwrite existing files without explicit user confirmation.
- Do NOT skip the hub-link step when `require_moc_link=true` and `hubs`
  is non-empty.
- Do NOT use any tag in `tag-policy.banned_tags`.
- Do NOT place `tags:` on the same line as the closing `---` of frontmatter.
- Do NOT call this skill in parallel — each write may affect dedup state for the next.
- Do NOT bypass `wiki-indexer` by editing `index.md` directly.
- Do NOT delete raw files when backlinking.
