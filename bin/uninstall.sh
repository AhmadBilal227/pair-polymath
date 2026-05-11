#!/usr/bin/env bash
# Pair Polymath uninstaller. Removes our settings.json entries; preserves
# everything else (including user's other hooks and the override dir + cache
# by default — separate prompt for those).

set -u

PP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
USER_CONFIG_DIR="$CLAUDE_DIR/pair-polymath"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; }
prompt() { printf '  \033[36m?\033[0m %s ' "$1"; }

step "Pair Polymath uninstaller"

if [ ! -f "$SETTINGS_FILE" ]; then
  warn "No settings.json found at $SETTINGS_FILE — nothing to remove."
else
  bak="${SETTINGS_FILE}.bak.uninstall.$(date +%s)"
  cp "$SETTINGS_FILE" "$bak"
  ok "backup: $bak"

  tmp=$(mktemp)
  jq --arg sl "bash $PP_ROOT/bin/statusline.sh" \
     --arg hook_user "$PP_ROOT/hooks/inject-monitor-insight.sh" \
     --arg hook_post "$PP_ROOT/hooks/cache-test-result.sh" '
    # Remove our statusLine if it points to our script
    (if .statusLine?.command == $sl then del(.statusLine) else . end)
    |
    # Filter out any hook entry whose hooks[].command matches ours
    .hooks.UserPromptSubmit |= (
      map(.hooks |= map(select(.command != $hook_user)))
      | map(select(.hooks | length > 0))
    )
    |
    .hooks.PostToolUse |= (
      map(.hooks |= map(select(.command != $hook_post)))
      | map(select(.hooks | length > 0))
    )
  ' "$SETTINGS_FILE" > "$tmp"

  if jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$SETTINGS_FILE"
    ok "settings.json: our entries removed; other hooks preserved"
  else
    warn "Merge produced invalid JSON — original preserved at $SETTINGS_FILE"
    rm -f "$tmp"
  fi
fi

if [ -d "$USER_CONFIG_DIR" ]; then
  step "User override + cache dir"
  printf '  Path: %s\n' "$USER_CONFIG_DIR"
  prompt "Remove user override dir + cache? [y/N]"
  read -r ans
  case "${ans:-N}" in
    [Yy]*) rm -rf "$USER_CONFIG_DIR" && ok "removed" ;;
    *)     ok "preserved" ;;
  esac
fi

printf '\n\033[1m\033[32m✓ Pair Polymath uninstalled.\033[0m\n'
printf '  Open a new Claude Code session for changes to take effect.\n'
