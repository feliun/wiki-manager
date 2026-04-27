---
description: "Standalone ingest processing — expands all raw captures into structured wiki notes."
---

# Ingest

Expand every raw capture in the configured `raw_folder` into a structured wiki note that complies with the active wiki-manager policies.

---

## Process

1. **Resolve config.** Invoke the `manifest-resolver` skill to load
   `vault-paths`, `note-types`, `tag-policy`, `concept-hubs`, `linking-rules`,
   and `naming-convention`.
2. **Filter unprocessed files.** Use `obsidian:obsidian-cli` to query the vault
   index directly:
   ```bash
   obsidian search query='path:{raw_folder} [type:raw] -[status:done]'
   ```
   Substituting `{raw_folder}` with the resolved value. This leverages
   Obsidian's property index — no file reads needed. If no results are
   returned, report "no files to process" and stop.
   **Fallback** (when Obsidian isn't running):
   ```bash
   grep -rL "^status: done" {raw_folder}/*.md 2>/dev/null
   ```
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
