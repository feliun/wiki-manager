#!/bin/bash
# wiki-logger.sh — PostToolUse hook for Write|Edit
# Appends a timestamped entry to the wiki log when vault files change.
# Also re-indexes qmd so search stays fresh.
#
# Dependencies: jq (required), qmd (optional — skipped when missing).
#
# Vault root resolution (first match wins):
#   1. $WIKI_VAULT_ROOT env var
#   2. vault_root field in $CLAUDE_PROJECT_DIR/.wiki-manager/vault-paths.yaml
#   3. vault_root field in $CLAUDE_PROJECT_DIR/system/memory/config/vault-paths.yaml
#   4. vault_root field in ~/.claude/wiki-manager/vault-paths.yaml
#
# A `vault_root: .` in any of those files resolves to $CLAUDE_PROJECT_DIR.
# If no vault root can be resolved, the hook exits silently.
#
# Log file path is resolved from `log_file` in the same vault-paths.yaml
# files (relative to vault root). Falls back to `wiki/log.md` if unset.

set -e

# --- Resolve vault root ----------------------------------------------------

read_yaml_key() {
  # crude YAML parse: first `<key>: <value>` line, strip quotes/comments
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 1
  local val
  val=$(grep -E "^${key}:[[:space:]]*" "$file" | head -n1 \
        | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^[\"']//; s/[\"']$//")
  [ -n "$val" ] && printf '%s' "$val"
}

read_vault_root() {
  read_yaml_key "$1" "vault_root"
}

read_log_file() {
  read_yaml_key "$1" "log_file"
}

resolve_vault_root() {
  if [ -n "$WIKI_VAULT_ROOT" ]; then
    printf '%s' "$WIKI_VAULT_ROOT"
    return 0
  fi

  local base="$CLAUDE_PROJECT_DIR"
  local candidates=()
  [ -n "$base" ] && candidates+=(
    "$base/.wiki-manager/vault-paths.yaml"
    "$base/system/memory/config/vault-paths.yaml"
  )
  candidates+=("$HOME/.claude/wiki-manager/vault-paths.yaml")

  local f val
  for f in "${candidates[@]}"; do
    val=$(read_vault_root "$f") || continue
    if [ "$val" = "." ] && [ -n "$base" ]; then
      printf '%s' "$base"
      return 0
    fi
    # expand ~ if present
    case "$val" in
      "~"|"~/"*) val="${HOME}${val#~}" ;;
    esac
    printf '%s' "$val"
    return 0
  done

  return 1
}

VAULT=$(resolve_vault_root) || exit 0
[ -n "$VAULT" ] || exit 0

# --- Resolve log file path -------------------------------------------------

resolve_log_file() {
  local base="$CLAUDE_PROJECT_DIR"
  local candidates=()
  [ -n "$base" ] && candidates+=(
    "$base/.wiki-manager/vault-paths.yaml"
    "$base/system/memory/config/vault-paths.yaml"
  )
  candidates+=("$HOME/.claude/wiki-manager/vault-paths.yaml")

  local f val
  for f in "${candidates[@]}"; do
    val=$(read_log_file "$f") || continue
    [ -n "$val" ] && printf '%s' "$val" && return 0
  done

  # Fallback default
  printf '%s' "wiki/log.md"
}

LOG_REL=$(resolve_log_file)

# --- Read tool payload -----------------------------------------------------

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')
[ -z "$FILE_PATH" ] && exit 0

# Only log changes within the vault
case "$FILE_PATH" in
  "$VAULT"/*) ;;
  *) exit 0 ;;
esac

# --- Log entry -------------------------------------------------------------

LOG="$VAULT/$LOG_REL"
NOTE_NAME=$(basename "$FILE_PATH" .md)
REL_PATH=${FILE_PATH#"$VAULT"/}

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
case "$TOOL_NAME" in
  Write) VERB="create" ;;
  Edit)  VERB="update" ;;
  *)     VERB="modify" ;;
esac

TODAY=$(date +%Y-%m-%d)
MONTH=$(date +%Y-%m)

mkdir -p "$(dirname "$LOG")"

if [ ! -s "$LOG" ]; then
  cat > "$LOG" << HEADER
---
type: reference
status: active
created: $(date +%d-%m-%Y)
---

# Wiki Log

Chronological record of wiki operations. Append-only.
HEADER
fi

if ! grep -q "^## $MONTH" "$LOG"; then
  printf '\n## %s\n' "$MONTH" >> "$LOG"
fi

echo "- $TODAY $VERB | [[$NOTE_NAME]] — \`$REL_PATH\`" >> "$LOG"

# --- Re-index qmd (optional) -----------------------------------------------

if command -v qmd >/dev/null 2>&1; then
  case "$REL_PATH" in
    *.md)
      qmd update >/dev/null 2>&1 || true
      qmd embed  >/dev/null 2>&1 &
      ;;
  esac
fi

exit 0
