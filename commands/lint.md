---
description: "Vault health audit — orphans, stale content, contradictions, missing links, rule compliance."
---

# Lint

Prevent knowledge decay. Find contradictions, stale claims, orphan pages,
missing concepts, weak cross-references, and content gaps across the vault.

When to use:
- On a regular cadence (e.g. weekly).
- After a batch of raw processing, to verify the new notes comply with rules.
- Whenever the user asks to "check vault health" or "audit the vault".

---

## Dependencies

- **`manifest-resolver` skill** — invoke first to resolve all wiki-manager configs.
- **`obsidian:obsidian-cli`** — required. Used for every vault query (orphans, dead ends, unresolved links, backlinks, file listing, tags, search). Authoritative tool for vault structural analysis.
- **`qmd`** — recommended. Used for full-text and semantic search where Obsidian CLI is insufficient.
- **Obsidian desktop app must be running** for the CLI to work.

---

## Data sources

Read these two files **first**, before running any checks. They scaffold most
checks below.

| File | What it provides | Saves you from |
|------|-----------------|----------------|
| `vault-paths.index_file` (e.g. `wiki/index.md`) | Wiki catalog with one-line summaries grouped by type | Opening every file. Use for: contradictions (topic clustering), concepts needing pages (recurring terms in summaries), duplicates (all titles in one list), data gaps (summaries reveal stubs) |
| `vault-paths.log_file` (e.g. `wiki/log.md`) | Timestamped create/update events, append-only | Stat-ing every file for modification dates. Use for: scoping "this week" checks, staleness detection without filesystem calls |

**Limitations:** index summaries are too short for semantic checks — still need
to read individual files for contradictions and stale claims. The log file only
covers events since it was created; older notes require Obsidian CLI or
filesystem queries.

---

## Checks

### 1. Orphan pages

Pages with **zero inbound links** from any other page in the vault. Disconnected
knowledge is invisible in the graph and unlikely to be rediscovered.

**Scope:** all of `{wiki_folder}` (and any other folders the user wants
audited).

**Process:**
1. Use Obsidian CLI backlinks for each page.
2. A page is orphan if it has 0 inbound links (excluding self-references).

**Output:** orphans sorted by creation date (oldest first — longest-neglected).

---

### 2. Missing cross-references

Surface connections the author missed.

**Scope:** files created or modified in the past 7 days — use the log file to
identify them.

**Process:**
1. Build a link-target index from the index file. Supplement with filenames
   listed by Obsidian CLI.
2. For each in-scope file, scan body text (excluding frontmatter and existing
   `[[wikilinks]]`) for plain-text mentions of any link target (case-insensitive,
   whole-word).
3. Also flag near-matches — e.g. file `Remote Work Culture` exists, text says
   "working remotely".
4. Ignore self-references.

**Output:**

| File | Plain-text match | Suggested link | Context |
|------|------------------|----------------|---------|
| `File A` | "automation" | `[[Automation]]` | "…we rely on **automation** to…" |

Sort by number of suggestions per file.

---

### 3. Concepts needing their own page

Important ideas that are referenced but have no dedicated page.

**Process:**
1. Collect all broken `[[wikilinks]]` via Obsidian CLI — pages someone intended
   to create but didn't.
2. Scan index summaries for **recurring proper nouns, technical terms, and
   phrases** that appear across 3+ entries but have no corresponding wiki page.
3. For deeper detection, read high-link-count files and look for terms repeated
   across them.
4. Merge, deduplicate, sort by frequency.

**Output:** concept, how many pages reference it, example source files.

---

### 4. Contradictions between pages

Conflicting claims across the vault.

**Scope:** all of `{wiki_folder}`.

**Process:**
1. Use the index to identify topic clusters — group pages by shared type,
   similar summaries, or overlapping terms.
2. Within each cluster, compare factual claims: dates, numbers, names,
   definitions, stated causes/effects.
3. Flag cases where two pages assert different values for the same thing.

**Output:** contradiction, both files, conflicting claims with quoted text,
which file was modified more recently.

---

### 5. Stale content

Outdated information before it misleads. Combines factual staleness with
abandoned action items.

**Process:**
1. **Stale claims** — Use the log file to find files not updated in >6 months.
   Read those files and flag content with dates, statistics, version numbers,
   market figures, or time-sensitive language ("currently", "as of", "recently").
   For files predating the log, fall back to filesystem mtimes.
2. **Stale action items** — Scan `{wiki_folder}` for notes with `status: active`
   or `status: pending` older than 30 days.

**Output:** two groups — stale claims (file, suspect passage, last modified),
stale actions (grouped by type, with age).

---

### 6. Data gaps

Thin or incomplete pages that could be enriched.

**Process:**
1. Scan index summaries for stubs ("pending", "TBD", "Blocked", very short
   descriptions). Read those files to confirm.
2. Scan `{wiki_folder}` for files with fewer than 50 words of body content
   (excluding frontmatter), and for placeholder patterns: "TODO", "TBD",
   "fill in", empty sections.
3. Assess whether a web search could fill the gap.

**Output:** file, what's missing, whether a web search could help (with
suggested query).

---

### 7. Stale raw items

Files in `{raw_folder}` older than 7 days that haven't been processed.

---

### 8. Duplicate or near-duplicate titles

Scan the index for very similar titles that might be duplicates worth merging.

---

### 9. Rule compliance

Validate notes created or modified this week against the active wiki-manager
configs.

**Process:**
1. Use the log file to identify wiki files created or modified in the past
   7 days.
2. Validate each file against:

| Config | Checks |
|--------|--------|
| `note-types.yaml` | Valid `type` field, type matches content and location |
| `note-types.yaml` (`flow`/`initial_status`) | Has a `status` field with a value valid for the type |
| `tag-policy.yaml` | No tags listed in `banned_tags`, no tags duplicating the type, tags from allowed lists |
| `linking-rules.yaml` | Links to at least one Concept Hub when `require_moc_link` is true; no `related:` arrays in frontmatter when `use_related_section` is true |
| `naming-convention.yaml` | Dated notes follow `dated_format`; no type prefixes; titles within `max_title_length` |

**Output:** violations grouped by config file. Show file and what's wrong.

---

## Output

```
VAULT LINT — DD-MM-YYYY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Orphan pages:          X
Missing cross-refs:    X
Concepts without page: X
Contradictions:        X
Stale content:         X (claims: Y, actions: Z)
Data gaps:             X
Stale raw items:       X
Duplicate titles:      X
Rule violations:       X across Y notes

[Details for each check with findings > 0, in order above]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Do NOT auto-fix issues. Present them for review. The user decides what to act on.

---

## Anti-patterns

- Do NOT auto-fix any detected issues — present them for review only.
- Do NOT use Glob for Obsidian-managed folders — use `obsidian:obsidian-cli` or `ls` via Bash.
- Do NOT skip the rule compliance check — it catches structural issues that other checks miss.
