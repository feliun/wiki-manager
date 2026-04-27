---
name: wiki-manager:feed
description: >
  Save conversation output to the vault. Captures generated text from the
  current context, suggests a title and target subfolder, then delegates the
  write to the `create-note` skill.
---

# Feed

Save substantive generated content from the current conversation as a
standalone vault note.

---

## When to use

After Claude has generated substantive text in the conversation — analysis, strategy doc, research, draft, plan, reflection — and the user wants to persist it as a vault note.

---

## Execution

### 1. Resolve config

Invoke the `manifest-resolver` skill to load `vault-paths` (for
`outputs_folder` and `outputs_subfolders`). `create-note` will resolve the
rest.

### 2. Identify the content

Scan the current conversation for the most recent substantive generated text: strategy, analysis, research summary, draft, reflection, or any other structured output the user wants to keep. If multiple candidates exist or it is ambiguous, ask the user which output to save.

### 3. Suggest title and target

Propose:

- **Title:** a clean, descriptive filename (without date prefix or extension —
  `create-note` will add the date per `naming-convention`). Title case with
  spaces.
- **Subfolder:** one of the values listed under
  `vault-paths.outputs_subfolders`. If the resolved list is empty, fall back
  to writing directly under `outputs_folder/` (pass an empty subfolder
  override).

Show the suggestion:

```
FEED — save to vault

Title:    {suggested title}
Location: {outputs_folder}/{chosen subfolder}/
```

If the user provides a different title or location, use theirs.

### 4. Confirm or adjust

The user may confirm, change the title, change the subfolder, or ask to trim the content. Apply any adjustments to the body text before delegating.

### 5. Delegate to `create-note`

Invoke the `create-note` skill with:

- `body`: the cleaned content (no frontmatter — `create-note` adds it).
  Preserve any existing wikilinks (`[[...]]`).
- `title_hint`: the confirmed title (without date prefix).
- `type_hint`: `reference` (default for feed-saved content).
- `target_root`: `outputs`.
- `target_subfolder_override`: the chosen subfolder.
- `extra_tags`: `[autofeed]` plus 2–3 relevant tags inferred from the content
  (`create-note` will validate against `tag-policy`).

`create-note` handles frontmatter assembly, Concept Hub linking (per
`linking-rules`), filename construction, the file write (via
`obsidian:obsidian-cli` with `Write` fallback), and skips index registration
because `target_root=outputs`.

If the file already exists at the target path, `create-note` will stop and
ask before overwriting. Surface that prompt to the user verbatim.

### 6. Report

Use the result returned by `create-note`:

```
FEED COMPLETE

File: {created path}
Size: ~{word count} words
Tags: [{tags from create-note result}]
```

If `create-note` returned warnings (e.g. Obsidian CLI fallback), show them.

---

## Edge cases

- **No generated content in context:** tell the user there's nothing to save;
  ask them to point to or paste what they want.
- **User specifies content directly:** use what they point to; don't search
  the conversation.
- **Content is very short (<50 words):** proceed anyway — the user decides
  what's worth saving.
- **Obsidian not running:** `create-note` falls back to the `Write` tool and
  flags the degradation in `warnings`. Surface that warning to the user.
