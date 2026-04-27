---
type: reference
status: active
created: 01-03-2026
tags: [skill, wiki-manager, config, manifest]
---
# Skill: Manifest Resolver

Purpose:
Resolve the live config files for wiki-manager from `commands/manifest.yaml`
before any command runs. Returns the absolute path of each resolved config so
downstream skills/agents can read them.

When to use:
- Before any `wiki-manager` command that needs config (`/ingest`, `/feed`, `/lint`).
- Standalone, to debug resolution: "Invoke manifest-resolver for domain: wiki-manager".

---

## Resolution algorithm

1. **Read** the manifest at `<plugin-root>/commands/manifest.yaml`.
2. **Pick the domain** from the calling command's namespace (always `wiki-manager` for this plugin).
3. **For each config key under the domain:**
   - Iterate `paths` in declared order.
   - Substitute tokens:
     - `$WORKSPACE` → the directory the user invoked the command from (current working directory).
     - `~` → the user's home directory.
   - Treat any other relative path as relative to the plugin root.
   - Check that the file exists and is readable.
   - **Return the first match.**
   - If nothing matches and `required: true`, flag as `❌ missing`.
   - If nothing matches and `required: false`, flag as `⚠️ optional, skipped`.

By spec, every key declares paths in this order:

1. `$WORKSPACE/.wiki-manager/<file>` — project-local override
2. `$WORKSPACE/system/memory/config/<file>` — vault-side config convention
3. `config/<file>` — plugin defaults (shipped)
4. `~/.claude/wiki-manager/<file>` — personal override

First match wins.

---

## Output

Emit a compact status block the calling command can reference:

```
Config resolution (wiki-manager):
  ✅ vault-paths        → <abs path>
  ✅ note-types         → <abs path>
  ✅ tag-policy         → config/tag-policy.yaml (default)
  ⚠️ concept-hubs        → not found (optional)
  ✅ linking-rules      → config/linking-rules.yaml (default)
  ✅ naming-convention  → config/naming-convention.yaml (default)
```

Collapse to a single line if every key resolved from the same root:

```
Config: all resolved (6/6 from $WORKSPACE/system/memory/config/)
```

---

## Error handling

- If `manifest.yaml` is missing or unreadable, report the error and abort the calling command — there is no safe default.
- A missing **required** config (`required: true`) is a hard failure for the calling command.
- A missing **optional** config is logged with `⚠️` and the calling command continues with shipped defaults from `config/`.

---

## Anti-patterns

- Do NOT bypass the manifest by hardcoding config paths in commands or skills.
- Do NOT silently use a default when a `required: true` config is missing — surface the failure.
- Do NOT cache resolved paths across commands — re-resolve each invocation, configs may have moved.
