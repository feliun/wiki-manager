---
type: reference
status: active
created: 06-04-2026
tags: [skill, wiki-manager, obsidian]
---
# Skill: Wiki Indexer

Purpose:
Maintain the configured `index_file` as a structured catalog of all wiki notes,
organized by type with one-line summaries.

When to use:
- After creating or expanding a wiki note (called from `expand-raw-ideas`).
- After deleting or renaming a wiki note.
- When the user asks to rebuild or update the wiki index.
- From any workflow that adds notes to the wiki.

---

## Dependencies

- **`manifest-resolver` skill** — to resolve `vault-paths` (for `wiki_folder`, `index_file`) and `note-types` (for canonical section order).
- **`obsidian:obsidian-cli` skill** — to list wiki files, read frontmatter, and search.

---

## Index file

- **Location:** the resolved `vault-paths.index_file` (default `wiki/index.md`).
- **Wiki structure:** notes live in `{wiki_folder}/{type}/` subfolders.
- **Format:**
  - Frontmatter with `type: reference`, `status: active`.
  - One H1: `# Wiki Index`.
  - One H2 per note type that has at least one note.
  - Each entry: `- [[Note Title]] — one-line summary`.
  - Entries sorted alphabetically within each section.
  - Empty sections are omitted.

---

## Canonical section order

Section order follows the **key order in `note-types.yaml`**. Render each type as
a Title-Case H2 derived from the key (e.g. `to-do` → `## To-Do`,
`moc` → `## MOC`). This means changes to the user's `note-types.yaml` flow
through here without code edits.

---

## Process

### Mode A: add a single note (default)

When called with a filename, type, and summary:

1. Read the index file.
2. Find the H2 section matching the note's type. If absent, create it in the
   canonical position derived from `note-types.yaml`.
3. Insert `- [[Note Title]] — {summary}` in alphabetical position within the
   section.
4. Write the updated file.

### Mode B: full rebuild

When the index is missing, empty, or the user requests a rebuild:

1. List all subfolders under `{wiki_folder}` — each is a note type.
2. For each file in each subfolder, read the file. Use the subfolder name as
   `type` and extract the first sentence (or first heading) as the summary.
3. Group entries by type in the canonical order from `note-types.yaml`.
4. Write the complete index file.

---

## Output format

```markdown
---
type: reference
status: active
created: DD-MM-YYYY
---

# Wiki Index

Catalog of all wiki notes, organized by type. Auto-maintained by wiki-indexer.

## Idea

- [[2026-04-03 AI agents as junior employees]] — Frame agents as hires, not tools

## Book

- [[2026-02-15 The Almanack of Naval Ravikant]] — Leverage, judgment, and specific knowledge
```

---

## Anti-patterns

- Do NOT add system notes (reference, reflection, meeting, raw) to the index — wiki notes only.
- Do NOT write summaries longer than one sentence.
- Do NOT duplicate entries — check before inserting.
- Do NOT leave empty sections in the file.
- Do NOT hardcode the section order — derive it from `note-types.yaml`.
