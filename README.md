# Wiki Manager

> A Claude Code plugin that curates a markdown-based wiki end-to-end. Ingests raw captures, expands them into well-structured notes, maintains the wiki graph, and audits vault health. Optimized for Obsidian, works with any markdown vault.

## Prerequisites

- **[Obsidian CLI](https://github.com/Yakitrak/obsidian-cli)** — required. Used by every command for vault queries.
- **[qmd](https://github.com/Yakitrak/qmd)** — required. Used for full-text and semantic search.
- **jq** — required (used by the `wiki-logger` hook). Install via `brew install jq` or your package manager.
- **[xurl](https://github.com/mangopdf/xurl)** — required only for `/pull-tweets`. Install via `brew install mangopdf/utils/xurl`, then `xurl auth login`.
- The **Obsidian desktop app must be running** for the CLI to work.

## Installation

### Via the plugin marketplace

```
/plugin install wiki-manager
```

### Via clone

```
git clone https://github.com/feliun/wiki-manager.git ~/path/to/wiki-manager
ln -s ~/path/to/wiki-manager ~/.claude/plugins/wiki-manager
```

## Configuration

Wiki Manager reads its policies from YAML files. Each config key is resolved
on first match in this order:

1. `$WORKSPACE/.wiki-manager/<file>` — project-local override
2. `$WORKSPACE/system/memory/config/<file>` — vault-side config convention
3. `<plugin-root>/config/<file>` — plugin defaults (shipped)
4. `~/.claude/wiki-manager/<file>` — personal override

`$WORKSPACE` is the directory in which the user invokes the command. Copy any
file from `config/` to one of the above locations and customize.

| Config file | Purpose |
|-------------|---------|
| `vault-paths.yaml` | Logical-to-physical path mapping (`raw_folder`, `wiki_folder`, etc.) |
| `note-types.yaml` | Valid note types, initial statuses, and lifecycle flows |
| `tag-policy.yaml` | Allowed tags, banned tags, tag-vs-wikilink rules |
| `concept-hubs.yaml` | Wikilinks to the Maps of Content (MOCs) used by the vault |
| `linking-rules.yaml` | MOC link requirement, related-section policy, wikilinks-vs-tags |
| `naming-convention.yaml` | Filename rules for wiki notes |

The plugin ships generic defaults. Most users only need to fill `concept-hubs.yaml`
and (optionally) tighten `tag-policy.yaml` to their vocabulary.

## Commands

| Command | Description |
|---------|-------------|
| `/ingest` | Process every raw capture in `raw_folder` into a structured wiki note. |
| `/feed` | Save substantive conversation output to `outputs_folder/<subfolder>/`. |
| `/lint` | Vault health audit: orphans, stale content, contradictions, missing links, rule compliance. |

## Skills

| Skill | Description |
|-------|-------------|
| `manifest-resolver` | Resolves config file paths from `commands/manifest.yaml` before any command runs. |
| `expand-raw-ideas` | Transforms a single raw capture into a structured wiki note following the active configs. |
| `wiki-indexer` | Maintains the wiki index (`index_file`) catalog when notes are added, removed, or renamed. |

## Agents

| Agent | Description |
|-------|-------------|
| `raw-expander` | Batch-processes every raw capture using the active configs. Self-contained. |

## Hooks

| Hook | Description |
|------|-------------|
| `wiki-logger.sh` | PostToolUse hook for `Write`/`Edit`. Appends a timestamped entry to the configured `log_file` when a vault file changes, and re-indexes `qmd`. |

## Integration with other plugins

`/ingest` and `/lint` are designed to be safe to invoke from another plugin —
e.g. an end-of-day routine that runs `/ingest` after capturing the day's notes,
or a weekly automation that runs `/lint`. Every command is standalone and runs
without any other plugin installed.

## License

MIT
