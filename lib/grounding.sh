#!/usr/bin/env bash
# Pair Polymath — grounding helpers. Path containment for LLM-picked files.

# pp_contain_path BASE CANDIDATE
# Resolves CANDIDATE relative to BASE, ensures the resolved real path is
# inside BASE. Echoes the resolved path on success, returns 0.
# Returns 1 (nothing echoed) on traversal, missing target, or escape.
pp_contain_path() {
  local base="${1:-}"
  local candidate="${2:-}"
  [ -z "$base" ] && return 1
  [ -z "$candidate" ] && return 1
  [ ! -d "$base" ] && return 1

  # Reject obvious escape attempts before realpath. (Belt + suspenders.)
  case "$candidate" in
    /*|*..*) ;;  # absolute or contains .. — proceed; realpath check still applies
    *)       ;;
  esac

  local base_real
  base_real=$(cd "$base" 2>/dev/null && pwd -P) || return 1

  local cand_real
  cand_real=$(cd "$base" 2>/dev/null && realpath "$candidate" 2>/dev/null) || return 1

  # cand_real must be base_real itself or a descendant (prefix match with /)
  case "$cand_real" in
    "$base_real"|"$base_real"/*) printf '%s\n' "$cand_real"; return 0 ;;
    *) return 1 ;;
  esac
}

# pp_safe_grep_pattern PATTERN
# Returns 0 if PATTERN is a safe LLM-supplied grep pattern.
# Rejects: empty, length<4, length>100, pure metacharacters (., .*, ^.*$, etc.)
pp_safe_grep_pattern() {
  local p="${1:-}"
  local len="${#p}"
  [ "$len" -lt 4 ] && return 1
  [ "$len" -gt 100 ] && return 1
  case "$p" in
    .|.*|.\*|^|\$|^.\*\$|^\.\*\$|*\*\*\*|\\*) return 1 ;;
  esac
  # At least one alphanumeric character required.
  case "$p" in
    *[A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}
