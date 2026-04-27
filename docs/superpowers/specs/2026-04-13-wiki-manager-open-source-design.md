# Wiki-Manager — Open-Source Refactor Design

**Date:** 2026-04-13
**Status:** Approved for implementation planning

## Goal

Ship `wiki-manager` as a generic, fully-configurable open-source Claude Code plugin. Zero personal references. Works against any markdown wiki (Obsidian-optimized). Preserve the current vault owner's behavior via a one-time content migration into live config files at their existing vault location.

## Design Principles

- **CLAUDE.md must stay minimal whilst highly effective.** Hard constraint — no exceptions. Target ≤ 40 lines. Keep only: identity bullets, manifest reference, component table, core operational rules. Every word must earn its place. Reviewer blocker if violated.
- **Config over code.** Every policy a user might want to change lives in YAML, not in agent/skill prose.
- **Zero personal references in the plugin tree.** Anything personal belongs in the vault owner's config, not the plugin.
- **First-match wins, always.** Config resolution is explicit and predictable.

## Scope

**In:**
- Strip all personal references (names, project names, vault path, personal MOCs, personal subfolders).
- Multi-layer config resolution: `$WORKSPACE` → plugin defaults → `~/.claude/` (mirrors `ceo-coach`).
- Move hardcoded policies (note types, statuses, tags, concept hubs, naming, linking rules) out of the agent into YAML config files.
- Package as a Claude plugin (`.claude-plugin/plugin.json` + `marketplace.json`).
- README with clear dependency install (Obsidian CLI + qmd, both required).
- Hook reads vault path from config instead of hardcoding.
- Migrate the current vault owner's embedded content into live config files at their vault's existing config path.
- **Rewrite CLAUDE.md to be minimal whilst highly effective.**

**Out:**
- Changing command or skill semantics (only generalization).
- Adding new commands or skills.
- Tooling to migrate other third-party forks (only one vault owner exists at refactor time).

## Working Locations

- **Source (read-only, untouched):** `/Users/felipepolo/Documents/Digital Garden/agents/wiki-manager/`
- **Target (all writes):** `~/Documents/development/ai/wiki-manager/`
- **Vault owner's runtime config (writes during migration only):** `/Users/felipepolo/Documents/Digital Garden/system/memory/config/`

All refactor work — `.claude-plugin/`, generic defaults in `config/`, stripped agent/skill files, new CLAUDE.md, README, LICENSE — lands in `~/Documents/development/ai/wiki-manager/`. The existing `Digital Garden/agents/wiki-manager/` is not modified.

This mirrors how `ceo-coach` is structured: real plugin lives under `~/Documents/development/ai/`, and if the vault owner wants it accessible inside the Digital Garden tree, they can symlink `Digital Garden/agents/wiki-manager → ~/Documents/development/ai/wiki-manager` at the end (same pattern used for `ceo-coach`). Symlink creation is optional, gated on user confirmation.

## Chosen Approach

**Thin rewrite: strip + parameterize, produced as a copy.** Start from the current source, produce a cleaned copy at the target location. Remove personal references inline. Move embedded policies into YAML. Add `.claude-plugin/` metadata. Update manifest to use `$WORKSPACE` tokens. Low risk, source remains intact as a reference.

Rejected:
- **Full reorganization into `src/`, `examples/`, `docs/`** — disturbs every file, complicates internal references, no meaningful benefit.
- **Rewrite as library + plugin shell** — grossly overscoped for a markdown-driven agent system.

## Architecture

### Repo layout after refactor

```
wiki-manager/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── CLAUDE.md                  # minimal, ≤ 40 lines
├── README.md                  # overview + setup + dependencies
├── LICENSE                    # MIT
├── commands/
│   ├── manifest.yaml          # multi-layer resolution config
│   ├── ingest.md
│   ├── feed.md
│   └── lint.md
├── skills/
│   ├── manifest-resolver/SKILL.md
│   ├── expand-raw-ideas.md
│   └── wiki-indexer.md
├── agents/
│   └── raw-expander.md        # policies read from config, not embedded
├── hooks/
│   └── wiki-logger.sh         # vault path from config
├── config/                    # ships real working defaults
│   ├── vault-paths.yaml
│   ├── note-types.yaml
│   ├── tag-policy.yaml
│   ├── concept-hubs.yaml      # NEW
│   ├── linking-rules.yaml     # NEW
│   └── naming-convention.yaml # NEW
└── references/
    └── obsidian-conventions.md
```

### Config layer resolution (per key)

First match wins:

1. `$WORKSPACE/.wiki-manager/<file>` — user's project override
2. `$WORKSPACE/<configured-path>` — user's custom path in manifest
3. `<plugin-root>/config/<file>` — shipped generic defaults
4. `~/.claude/wiki-manager/<file>` — user's personal override

### Plugin identity

- **Name:** `wiki-manager`
- **License:** MIT
- **Packaging:** Claude Code plugin via `.claude-plugin/plugin.json` + `marketplace.json`
- **Distribution:** primary = plugin marketplace; secondary = clone-and-symlink

## Config Schema

### `vault-paths.yaml`

```yaml
vault_root: .               # $WORKSPACE by default; or absolute path
raw_folder: raw/
wiki_folder: wiki/
outputs_folder: outputs/
index_file: wiki/index.md
log_file: wiki/log.md
outputs_subfolders:         # drives /feed suggestions
  - drafts
  - research
  - analysis
  - reference
```

### `note-types.yaml` (generic defaults)

```yaml
types:
  note:      { initial_status: active,  flow: [inbox, active, done] }
  idea:      { initial_status: active,  flow: [inbox, active, done, evergreen] }
  reference: { initial_status: active,  flow: [active] }
  moc:       { initial_status: active,  flow: [active] }
  to-do:     { initial_status: active,  flow: [inbox, active, done] }
  to-read:   { initial_status: pending, flow: [inbox, pending, active, done] }
  book:      { initial_status: active,  flow: [inbox, active, done, evergreen] }
  content:   { initial_status: draft,   flow: [inbox, draft, ready, published] }
```

### `tag-policy.yaml` (generic defaults)

- No banned tags shipped.
- Empty `allowed_domain_tags` / `allowed_format_tags` (or sensible minimal set).
- User fills for their taxonomy.

### `concept-hubs.yaml` (NEW)

```yaml
# List of MOC wikilinks. Every expanded note must link to ≥ 1 when require_moc_link is true.
# Default ships empty. When empty, the agent downgrades the MOC rule to a warning.
hubs: []
```

### `linking-rules.yaml` (NEW)

```yaml
require_moc_link: true
prefer_wikilinks_over_tags: true
use_related_section: true
```

### `naming-convention.yaml` (NEW)

```yaml
dated_format: "YYYY-MM-DD Title in natural language.md"
timeless_types: [moc]
max_title_length: 60
preserve_accents: true
word_separator: space
```

### `commands/manifest.yaml`

```yaml
wiki-manager:
  vault-paths:
    paths:
      - $WORKSPACE/.wiki-manager/vault-paths.yaml
      - $WORKSPACE/system/memory/config/vault-paths.yaml
      - config/vault-paths.yaml
      - ~/.claude/wiki-manager/vault-paths.yaml
    required: true
    format: yaml
  note-types:
    paths:
      - $WORKSPACE/.wiki-manager/note-types.yaml
      - $WORKSPACE/system/memory/config/note-types.yaml
      - config/note-types.yaml
      - ~/.claude/wiki-manager/note-types.yaml
    required: false
    format: yaml
  # … same pattern for tag-policy, concept-hubs, linking-rules, naming-convention
```

Note: the current vault owner's path (`$WORKSPACE/system/memory/config/...`) is preserved as a resolution entry so no behavior regression occurs for them.

## Agent Behavior Change

`raw-expander.md` and `expand-raw-ideas.md` both load their policy tables from resolved config at start of execution, rather than reading from embedded text. Anchor changes:

- **Note type table** → loaded from `note-types.yaml`
- **Status lifecycle** → loaded from `note-types.yaml`
- **Concept Hubs list** → loaded from `concept-hubs.yaml`
- **Banned tags table** → loaded from `tag-policy.yaml`
- **Allowed tags** → loaded from `tag-policy.yaml`
- **Naming rules** → loaded from `naming-convention.yaml`
- **Linking rules** → loaded from `linking-rules.yaml`

When `concept-hubs.yaml` is empty, the "link to ≥ 1 MOC" rule downgrades to a warning.

## Files to Change

### Major rewrites

- **`agents/raw-expander.md`** — delete all embedded policy tables (note types, status, tags, naming, linking, concept hubs). Replace with instructions to load each from resolved config. Delete all mentions of personal projects or names. Delete the specific concept-hub list, banned-tag table, and allowed-tag lists.
- **`hooks/wiki-logger.sh`** — remove hardcoded `VAULT=`. Read `vault_root` from resolved `vault-paths.yaml` (or `WIKI_VAULT_ROOT` env var override). Keep `qmd` calls (documented dependency). Keep `jq` dependency (documented).
- **`commands/manifest.yaml`** — rewrite with `$WORKSPACE` token + 3-layer resolution. Add entries for `concept-hubs`, `linking-rules`, `naming-convention`.

### Targeted edits

- **`CLAUDE.md`** — minimal whilst highly effective (hard constraint, see Design Principles). Target ≤ 40 lines. Keep: identity bullets, manifest reference, component table, core operational rules. Drop: everything else. Every remaining line must earn its place.
- **`commands/ingest.md`** — polish, remove any lingering personal reference.
- **`commands/feed.md`** — drop hardcoded subfolders; read `outputs_subfolders` from config.
- **`commands/lint.md`** — remove `Felipe says`, remove `/cob` coupling, list qmd + Obsidian CLI as dependencies explicitly. Keep the 9 checks.
- **`skills/expand-raw-ideas.md`** — reference config-driven rules; remove references to user-specific MOC pages like `[[Home]]`.
- **`skills/wiki-indexer.md`** — canonical section order derived from `note-types.yaml` key order, not hardcoded.
- **`skills/manifest-resolver/SKILL.md`** — update algorithm doc to describe 3-layer token resolution. Remove "graceful-degradation" section (not applicable to this plugin).

### New files

- `.claude-plugin/plugin.json` — `{ name, version, description, license: "MIT", author }`
- `.claude-plugin/marketplace.json` — standard marketplace metadata
- `LICENSE` — MIT
- `config/concept-hubs.yaml` — empty `hubs: []`
- `config/linking-rules.yaml` — default rules
- `config/naming-convention.yaml` — default naming
- `README.md` — full rewrite per outline below

### Renames

- `config/*.yaml.example` → `config/*.yaml` (ship as working defaults).

### Deletions

- Any reference to `system/memory/` and `system/rules/` inside plugin files (those are user-specific vault conventions, not plugin concerns). Manifest still lists them as resolution paths, but no plugin doc describes them.

## Current Vault Owner Migration

During implementation, create and populate these files at the current vault owner's existing config location (`$WORKSPACE/system/memory/config/`):

- **`concept-hubs.yaml`** — copy the hub list currently embedded in `raw-expander.md`:
  ```yaml
  hubs:
    - "[[AI]]"
    - "[[Claude]]"
    - "[[AI Agents]]"
    - "[[Agentic Engineering]]"
    - "[[Orbitant OS]]"
    - "[[MCP]]"
    - "[[Automation]]"
    - "[[LinkedIn]]"
    - "[[Personal branding]]"
    - "[[CEO Leadership]]"
    - "[[Obsidian]]"
    - "[[OpenClaw]]"
    - "[[Networking]]"
  ```
- **`linking-rules.yaml`** — match current behavior (`require_moc_link: true`, `prefer_wikilinks_over_tags: true`, `use_related_section: true`).
- **`naming-convention.yaml`** — match current convention (`YYYY-MM-DD Title in natural language.md`, `timeless_types: [moc]`, `max_title_length: 60`, `preserve_accents: true`, `word_separator: space`).
- **`tag-policy.yaml`** — extend existing file with banned tags currently in `raw-expander.md`:
  ```yaml
  banned_tags:
    - { tag: content,          use_instead: "type: content in frontmatter" }
    - { tag: raw,              use_instead: "status: inbox in frontmatter" }
    - { tag: moc,              use_instead: "type: moc in frontmatter" }
    - { tag: inbox,            use_instead: "status: inbox in frontmatter" }
    - { tag: orbitant,         use_instead: "[[Orbitant OS]] wikilink" }
    - { tag: openclaw,         use_instead: "[[OpenClaw]] wikilink" }
    - { tag: claude,           use_instead: "[[Claude]] wikilink" }
    - { tag: claude-code,      use_instead: "[[Claude]] wikilink" }
    - { tag: ai,               use_instead: "[[AI]] wikilink" }
    - { tag: agents,           use_instead: "[[AI Agents]] wikilink" }
    - { tag: automation,       use_instead: "[[Automation]] wikilink" }
    - { tag: obsidian,         use_instead: "[[Obsidian]] wikilink" }
    - { tag: networking,       use_instead: "[[Networking]] wikilink" }
    - { tag: tools,            use_instead: "specific tool MOC wikilink" }
    - { tag: workflow,         use_instead: "remove (too vague)" }
    - { tag: productivity,     use_instead: "remove (too vague)" }
  ```
- **`note-types.yaml`** — create/verify with current 9 types (content, idea, company, book, inspiration, moc, to-do, to-read, to-buy) and their current statuses/flows.

## README Structure

```
# Wiki Manager

> 1-paragraph pitch

## Prerequisites

- Obsidian CLI (required) — <install link>
- qmd (required) — <install link>
- jq (required for hooks) — <install link>
- Obsidian desktop app must be running for CLI

## Installation

### Via plugin marketplace
    /plugin install wiki-manager

### Via clone
    git clone …
    # symlink or copy into ~/.claude/plugins/

## Configuration

Three-layer resolution (first match wins):
1. $WORKSPACE/.wiki-manager/<file>
2. <plugin-root>/config/<file>  (shipped defaults)
3. ~/.claude/wiki-manager/<file>

Copy `config/*.yaml` to any of these locations and customize.

## Commands

| Command | Description |
| … |

## Skills / Agents / Hooks

| … |

## Integration with other agents/routines

One paragraph on how `/ingest` and `/lint` can be invoked from a user's
end-of-day routine or another plugin (no personas named).

## License

MIT
```

## Dependencies

- **Obsidian CLI** — required
- **qmd** — required
- **jq** — required (hook only)
- Obsidian app must be running for CLI commands

## Risks & Mitigations

- **Config-driven agent re-reads files on each command invocation** — mitigated by running the manifest resolver once per command, passing resolved values to downstream skills.
- **Empty `concept-hubs.yaml` makes "must link to MOC" rule fail for new users** — mitigated by downgrading the rule to a warning when the hub list is empty.

## Validation Checklist

- [ ] Target plugin tree exists at `~/Documents/development/ai/wiki-manager/`; source at `Digital Garden/agents/wiki-manager/` is untouched.
- [ ] `grep -ri "orbitant\|openclaw\|felipe\|digital garden"` against the target tree returns zero hits.
- [ ] `.claude-plugin/plugin.json` + `marketplace.json` present and valid.
- [ ] `/ingest` runs against a sample vault and produces a correctly typed, indexed note.
- [ ] `/lint` runs against a sample vault without error.
- [ ] `/feed` uses `outputs_subfolders` from config, not hardcoded list.
- [ ] Hook resolves vault path from config (no hardcoded path anywhere in `hooks/`).
- [ ] CLAUDE.md is minimal whilst highly effective — ≤ 40 lines, every line earns its place.
- [ ] Current vault owner's config files present at `$WORKSPACE/system/memory/config/` with migrated content; running `/ingest` produces identical behavior to the pre-refactor version.
- [ ] README lists all required dependencies with install links.

## Execution Order

All file writes below happen under `~/Documents/development/ai/wiki-manager/` unless explicitly marked otherwise.

1. Create target directory `~/Documents/development/ai/wiki-manager/` and copy source tree from `Digital Garden/agents/wiki-manager/`, excluding `docs/` and `.git*`.
2. Initialize `git` in the target directory.
3. Create `.claude-plugin/plugin.json` + `marketplace.json` + `LICENSE`.
4. Write generic defaults in `config/` (including new YAML files; rename `*.yaml.example` → `*.yaml`).
5. Update `commands/manifest.yaml` with 3-layer resolution + new keys.
6. Update `skills/manifest-resolver/SKILL.md` to reflect new algorithm.
7. Migrate current vault owner's content into live configs at `/Users/felipepolo/Documents/Digital Garden/system/memory/config/` (outside the plugin tree — this is the only write outside the target).
8. Refactor `agents/raw-expander.md` to load policies from config.
9. Refactor `skills/expand-raw-ideas.md` and `skills/wiki-indexer.md` similarly.
10. Update `hooks/wiki-logger.sh` to read vault path from config.
11. Strip personal references from all commands (`ingest.md`, `feed.md`, `lint.md`).
12. Rewrite `CLAUDE.md` (minimal whilst highly effective, ≤ 40 lines).
13. Rewrite `README.md`.
14. Run validation checklist against the target tree.
15. Ask user whether to replace `Digital Garden/agents/wiki-manager/` with a symlink to the new location (matches `ceo-coach` pattern). Do not execute without explicit confirmation.
