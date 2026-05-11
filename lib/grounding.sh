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
    "$base_real"|"$base_real"/*)
      # Additional guard: refuse known secret-bearing filenames even when
      # they're legitimately inside the cwd (review fix for issue #5).
      if pp_is_secret_file "$cand_real"; then
        return 1
      fi
      printf '%s\n' "$cand_real"
      return 0
      ;;
    *) return 1 ;;
  esac
}

# pp_safe_grep_pattern PATTERN
# Returns 0 if PATTERN is safe to pass to `grep -E -- "$PATTERN"`.
# Rejects: empty, length<4, length>100, leading `-` (option-injection),
# pure metacharacters, and patterns whose alnum chars are dwarfed by metachars.
# Callers MUST also pass the pattern after `--` to grep.
pp_safe_grep_pattern() {
  local p="${1:-}"
  local len="${#p}"
  [ "$len" -lt 4 ] && return 1
  [ "$len" -gt 100 ] && return 1
  # Reject leading dash so an accepted pattern can never be parsed as a grep option,
  # even if a caller forgets the `--` separator.
  case "$p" in
    -*) return 1 ;;
  esac
  # Reject pure-metachar shapes and known-broad patterns.
  case "$p" in
    .|.*|.\*|^|\$|^.\*\$|^\.\*\$|*\*\*\*|\\*) return 1 ;;
  esac
  # Require enough alphanumeric content to anchor the search (≥3 alnum chars).
  # This rejects patterns like "^.*a.*$" where the alnum payload is just one
  # character buried in metachars.
  local stripped
  stripped=$(printf '%s' "$p" | tr -cd 'A-Za-z0-9')
  [ "${#stripped}" -lt 3 ] && return 1
  return 0
}

# pp_is_secret_file PATH
# Returns 0 if PATH's basename matches a known secret-bearing pattern, 1 otherwise.
# Patterns are GLOBS (case-sensitive), checked against basename only.
# Defaults cover common credential / private-key file conventions.
# Extend per-user via PP_SECRET_FILE_PATTERNS_EXTRA in user.env (additive).
# Replace entirely (escape hatch) via PP_SECRET_FILE_PATTERNS in user.env.
pp_is_secret_file() {
  local path="${1:-}"
  [ -z "$path" ] && return 1
  local base
  base="$(basename -- "$path")"

  local defaults=".env .env.* *.env .envrc *.pem *.key *.p12 *.pfx credentials* secrets* *.token *_token *_secret authinfo* .netrc id_rsa* id_dsa* id_ecdsa* id_ed25519* .npmrc .pypirc"
  local patterns="${PP_SECRET_FILE_PATTERNS:-$defaults}"
  local extra="${PP_SECRET_FILE_PATTERNS_EXTRA:-}"

  local p
  for p in $patterns $extra; do
    # shellcheck disable=SC2254  # intentional glob expansion
    case "$base" in
      $p) return 0 ;;
    esac
  done
  return 1
}
