#!/usr/bin/env bash
# Pair Polymath — config loader. Sourced (not exec'd) by bin/statusline.sh.
# Resolution order: bin/../config/default.env  →  ~/.claude/pair-polymath/config/user.env

# Resolve plugin root from this file's location
_pp_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PP_ROOT="$(cd "$_pp_lib_dir/.." && pwd)"
export PP_ROOT

# Load defaults
if [ -f "$PP_ROOT/config/default.env" ]; then
  # shellcheck disable=SC1091
  . "$PP_ROOT/config/default.env"
fi

# Load user overrides (optional)
PP_USER_CONFIG="${HOME}/.claude/pair-polymath/config/user.env"
if [ -f "$PP_USER_CONFIG" ]; then
  # shellcheck disable=SC1091
  . "$PP_USER_CONFIG"
fi

# Derived paths
PP_CACHE_DIR="${PP_CACHE_DIR:-$HOME/.claude/cache}"
PP_STATE_DIR="${PP_STATE_DIR:-$HOME/.claude/pair-polymath}"
mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR" 2>/dev/null || true
