#!/usr/bin/env bash
# Pair Polymath — config loader. Sourced (not exec'd) by runtime scripts.
# Resolution order: config/default.env → $PP_USER_CONFIG

# Resolve plugin root from this file's location
_pp_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PP_ROOT="$(cd "$_pp_lib_dir/.." && pwd)"
export PP_ROOT

# Canonical storage roots. CLAUDE_DIR is the Claude Code integration root;
# PP_STATE_DIR is Pair Polymath's durable user-state root; PP_CACHE_DIR is
# volatile/telemetry cache. Explicit PP_* overrides win over CLAUDE_DIR.
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
PP_STATE_DIR="${PP_STATE_DIR:-$CLAUDE_DIR/pair-polymath}"
PP_USER_CONFIG="${PP_USER_CONFIG:-$PP_STATE_DIR/config/user.env}"
export CLAUDE_DIR PP_STATE_DIR PP_USER_CONFIG

# Load defaults
if [ -f "$PP_ROOT/config/default.env" ]; then
  # shellcheck disable=SC1091
  . "$PP_ROOT/config/default.env"
fi

# Load user overrides (optional)
if [ -f "$PP_USER_CONFIG" ]; then
  # shellcheck disable=SC1091
  . "$PP_USER_CONFIG"
fi

# Derived paths
PP_STATE_DIR="${PP_STATE_DIR:-$CLAUDE_DIR/pair-polymath}"
PP_CACHE_DIR="${PP_CACHE_DIR:-$CLAUDE_DIR/cache}"
PP_USER_CONFIG="${PP_USER_CONFIG:-$PP_STATE_DIR/config/user.env}"
export PP_CACHE_DIR PP_STATE_DIR PP_USER_CONFIG
mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR" 2>/dev/null || true

# Shared filename-safe session id policy for all cache artifacts. Claude
# session ids are not an authority boundary; treat them as untrusted path
# components and normalize before constructing filenames.
pp_sanitize_session_id() {
  local _sid="${1:-default}"
  _sid=$(printf '%s' "$_sid" | tr -cd 'a-zA-Z0-9._-' | cut -c1-64)
  [ -n "$_sid" ] || _sid="default"
  printf '%s' "$_sid"
}
