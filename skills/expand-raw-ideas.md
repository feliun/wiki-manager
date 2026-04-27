---
type: reference
status: active
created: 17-01-2026
tags: [skill, wiki-manager, obsidian]
---
# Skill: Expand Raw Ideas

Purpose:
Transform a single raw, unstructured capture into a high-quality wiki note that
follows the configured policies.

When to use:
- A note has `status: inbox` (or `type: raw`) and needs expansion.
- The user explicitly asks to "expand" or "develop" an idea.
- Called from `/ingest` or the `raw-expander` agent for a single file.

---

## Dependencies

- **`manifest-resolver` skill** — invoke first, to resolve the active wiki-manager configs (`vault-paths`, `note-types`, `tag-policy`, `concept-hubs`, `linking-rules`, `naming-convention`).
- **`obsidian:obsidian-markdown` skill** — invoke before writing any note. Authoritative reference for Obsidian-flavored markdown (frontmatter, wikilinks, callouts, embeds, tags).
- **`obsidian:defuddle` skill** — when the raw note contains a URL. Use `defuddle parse <url> --md` for clean source extraction.
- **`obsidian:obsidian-cli` skill** — for vault operations: searching for existing notes, checking backlinks, listing files.
- **`wiki-indexer` skill** — invoke after creating the wiki note to add it to the configured `index_file`.

---

## Process

1. Invoke **`manifest-resolver`** for `wiki-manager`. Load each resolved YAML and bind: `vault-paths`, `note-types`, `tag-policy`, `concept-hubs`, `linking-rules`, `naming-convention`.
2. Invoke **`obsidian:obsidian-markdown`** so all Obsidian syntax rules are available before writing.
3. Identify the core idea. If it has a URL, use `defuddle parse <url> --md` for the source content; fall back to WebFetch on failure.
4. **Determine the note type** by matching capture hints against the keys of `note-types`. Default to a generic type when ambiguous.
5. **Set the initial status** from `note-types[type].initial_status`.
6. **Write frontmatter** with proper Obsidian property types: `tags` as a YAML list, `created` in `DD-MM-YYYY`, link properties as `"[[Target]]"`. Newline between the last field and the closing `---`.
7. Rewrite the idea clearly in your own words. High signal, max 400 words.
8. Add structure with headings. Use callouts (`> [!tip]`, `> [!example]`, `> [!quote]`) when they add clarity.
9. **Link to Concept Hubs.** When `linking-rules.require_moc_link` is true and `concept-hubs.hubs` is non-empty, every note must wikilink to at least one hub. Use `obsidian:obsidian-cli` to search the vault for adjacent notes too. If the hub list is empty, log a warning and continue.
10. When `linking-rules.use_related_section` is true, place hub wikilinks under a `## Related` section at the end.
11. **Choose tags** from `tag-policy.allowed_*` lists. Reject any tag in `tag-policy.banned_tags` (surface the `use_instead` guidance). When `linking-rules.prefer_wikilinks_over_tags` is true and a Concept Hub exists for the topic, use the wikilink instead of a tag.
12. **Filename** per `naming-convention`: `dated_format` for normal notes, no date prefix when type is in `timeless_types`. Cap at `max_title_length`. Use `word_separator`. Preserve accents when `preserve_accents` is true.
13. Store the file in `{wiki_folder}/{type}/`. Create the subfolder if missing.
14. After the file is created, link it back to the original raw file (add an `## Expanded` section with a wikilink to the new note, set the raw file's `status` to `done`). **Never delete raw files.**
15. Invoke the **`wiki-indexer`** skill (Mode A) with filename, type, and a one-line summary to register the note in the configured `index_file`.

---

## Output

- Obsidian-flavored markdown following the `obsidian:obsidian-markdown` skill spec.
- Frontmatter with typed properties.
- Wikilinks for all internal references (never plain markdown links to vault notes).
- Callouts where they add clarity.
- Clear title.
- Structured sections.
- Ready for long-term reuse.

---

## Anti-patterns

- Do NOT invent facts — only expand what's present in the raw idea or its linked source.
- Do NOT overextend beyond the idea's intent.
- Do NOT delete raw files after expansion — only link and update status.
- Do NOT create notes without a hub wikilink when the hub list is non-empty and `require_moc_link` is true.
- Do NOT place `tags:` on the same line as the closing `---` of frontmatter.
- Do NOT use any tag in `tag-policy.banned_tags`.
