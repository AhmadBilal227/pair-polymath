#!/usr/bin/env bash
# Pair Polymath uninstaller. Removes our settings.json entries; preserves
# everything else (including user's other hooks and the override dir + cache
# by default — separate prompt for those).
#
# Match strategy: filter by BASENAME of our scripts (statusline.sh,
# inject-monitor-insight.sh, cache-test-result.sh) so an old install from
# a moved/renamed checkout still gets cleaned up (review fix M3).

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

  # Tmp file in the SAME directory as settings.json so mv stays atomic-rename
  # within the same filesystem (review fix carried back from bin/polymath
  # commit 491b2e5). Caught by the ENGINEERING lens on 2026-05-11.
  tmp=$(mktemp "${SETTINGS_FILE}.XXXXXX") || { warn "mktemp failed; settings.json untouched"; exit 0; }
  # Match by basename via jq's `test` regex so orphans from a moved checkout
  # still get cleaned up. The `// []` guards prevent jq from crashing when
  # the array is null/absent (review fix H2).
  jq '
    # Drop our statusLine if its command references our statusline.sh basename
    (if (.statusLine?.command // "") | test("statusline\\.sh") then del(.statusLine) else . end)
    |
    .hooks.UserPromptSubmit |= (
      (. // [])
      | map(.hooks |= ((. // []) | map(select((.command // "") | test("inject-monitor-insight\\.sh") | not))))
      | map(select((.hooks // []) | length > 0))
    )
    |
    .hooks.PostToolUse |= (
      (. // [])
      | map(.hooks |= ((. // []) | map(select((.command // "") | test("cache-test-result\\.sh") | not))))
      | map(select((.hooks // []) | length > 0))
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
