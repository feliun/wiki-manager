---
name: wiki-manager:feed
description: >
  Save conversation output to the vault. Captures generated text from the
  current context, suggests a title and target subfolder, writes the file,
  and indexes it.
---

# Feed

Save substantive generated content from the current conversation as a
standalone vault note.

---

## When to use

After Claude has generated substantive text in the conversation — analysis,
strategy doc, research, draft, plan, reflection — and the user wants to
persist it as a vault note.

---

## Execution

### 1. Resolve config

Invoke the `manifest-resolver` skill to load `vault-paths` (for
`outputs_folder` and `outputs_subfolders`) and `note-types`.

### 2. Identify the content

Scan the current conversation for the most recent substantive generated text:
strategy, analysis, research summary, draft, reflection, or any other
structured output the user wants to keep. If multiple candidates exist or it
is ambiguous, ask the user which output to save.

### 3. Suggest title and target

Propose:

- **Title:** a clean, descriptive filename prefixed with today's date
  (`YYYY-MM-DD`). Title case with spaces.
- **Subfolder:** one of the values listed under `vault-paths.outputs_subfolders`.
  If the resolved list is empty, fall back to writing directly under
  `outputs_folder/`.

Show the suggestion:

```
FEED — save to vault

Title:    {YYYY-MM-DD suggested title}.md
Location: {outputs_folder}/{chosen subfolder}/
```

If the user provides a different title or location, use theirs.

### 4. Confirm or adjust

The user may confirm, change the title, change the subfolder, or ask to trim
the content. Apply any adjustments before writing.

### 5. Format the content

Invoke the `obsidian:obsidian-markdown` skill for syntax reference before
writing.

Add YAML frontmatter:

```yaml
---
type: reference
status: active
created: {DD-MM-YYYY}
tags:
  - autofeed
  - {relevant tag 1}
  - {relevant tag 2}
---
```

- **`tags`**: always include `autofeed` as the first tag, then 2–3 relevant tags
  inferred from the content. Pull from the active `tag-policy.yaml` allowed lists.
- If the content already has frontmatter, merge — don't duplicate.
- Preserve any existing wikilinks (`[[...]]`) in the content.
- Do not modify the body unless the user asked for changes.

### 6. Write the file

Use Obsidian CLI to create the file:

```bash
obsidian create path="{outputs_folder}/{subfolder}/{title}.md" content="{formatted content}" silent
```

- Use `silent` so the file does not open in Obsidian.
- If the file already exists, warn the user and ask before overwriting.
- **Fallback:** If Obsidian CLI is unavailable, fall back to the Write tool and note the degradation with ⚠️.

### 7. Report

```
FEED COMPLETE

File: {outputs_folder}/{subfolder}/{title}.md
Size: ~{word count} words
Tags: [autofeed, {tags}]
```

---

## Edge cases

- **No generated content in context:** tell the user there's nothing to save; ask them to point to or paste what they want.
- **User specifies content directly:** use what they point to; don't search the conversation.
- **Content is very short (<50 words):** proceed anyway — the user decides what's worth saving.
- **Obsidian not running:** fall back to the Write tool. Note with ⚠️ that the file was created outside Obsidian and the vault may need a re-index.
