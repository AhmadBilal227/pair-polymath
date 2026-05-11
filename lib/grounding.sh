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
      # Reject if EITHER the original (link) path OR the resolved real path
      # matches the denylist. This catches: (a) named secrets (db.env),
      # (b) innocuously-named symlinks pointing to secret files (and vice
      # versa), (c) files inside secret-named directories on either side of
      # the symlink.
      #
      # For the dirname walk, only project-internal components are meaningful:
      # macOS resolves /var → /private/var, and "private" is a default
      # secret-dir pattern — checking the absolute realpath would produce
      # false positives on every macOS /tmp path. Trim the base prefix so
      # only the in-base portion is walked.
      local cand_rel="${cand_real#"$base_real"/}"
      [ "$cand_rel" = "$cand_real" ] && cand_rel=""  # candidate IS the base
      if pp_is_secret_file "$candidate" || pp_is_secret_file "$cand_rel"; then
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
# Returns 0 if PATH matches a known secret-bearing pattern, 1 otherwise.
# Two independent checks (either match → reject):
#   1. Basename glob match (case-insensitive) — e.g. .env, *.pem, id_rsa*
#   2. Any path-component matches a secret-DIRECTORY glob — e.g. secrets/,
#      .ssh/, .aws/. Catches secrets/config.json (innocuous basename).
# Inputs are case-folded for macOS APFS friendliness.
# Configure:
#   PP_SECRET_FILE_PATTERNS_EXTRA   additive file-basename patterns (user.env)
#   PP_SECRET_FILE_PATTERNS         REPLACE file-basename defaults (escape hatch)
#   PP_SECRET_DIR_PATTERNS_EXTRA    additive directory-name patterns (user.env)
#   PP_SECRET_DIR_PATTERNS          REPLACE directory-name defaults (escape hatch)
# Setting either REPLACE var to '' (explicit empty) disables that check.
# Whitespace-only is treated as user error → defaults + stderr warning.
pp_is_secret_file() {
  local path="${1:-}"
  [ -z "$path" ] && return 1

  local base base_lc
  base="$(basename -- "$path")"
  base_lc=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')

  local file_defaults=".env .env.* *.env .envrc *.pem *.key *.p12 *.pfx *credentials* *secrets* *.token *_token *_secret *_apikey authinfo* .netrc id_rsa* id_dsa* id_ecdsa* id_ed25519* *_rsa *_dsa *_ed25519 .npmrc .pypirc service-account*.json *.kubeconfig kubeconfig .git-credentials wp-config.php .aws_credentials .pgpass *.private_key"
  local dir_defaults="secrets private .secrets .credentials .keys .aws .ssh"

  # Distinguish UNSET (use defaults) from EMPTY (use empty list, disabling
  # the check). `${var:-default}` collapses both — `${var+set}` does not.
  local file_patterns dir_patterns
  if [ "${PP_SECRET_FILE_PATTERNS+set}" = "set" ]; then
    file_patterns="$PP_SECRET_FILE_PATTERNS"
  else
    file_patterns="$file_defaults"
  fi
  if [ "${PP_SECRET_DIR_PATTERNS+set}" = "set" ]; then
    dir_patterns="$PP_SECRET_DIR_PATTERNS"
  else
    dir_patterns="$dir_defaults"
  fi

  # Whitespace-only is almost certainly user error — fall back to defaults
  # with a stderr warning. (Genuine empty-string still disables.)
  case "${file_patterns// /}" in
    '')
      if [ "${PP_SECRET_FILE_PATTERNS+set}" = "set" ] && [ -n "$file_patterns" ]; then
        printf 'pp_is_secret_file: PP_SECRET_FILE_PATTERNS is whitespace-only; using defaults\n' >&2
        file_patterns="$file_defaults"
      fi
      ;;
  esac
  case "${dir_patterns// /}" in
    '')
      if [ "${PP_SECRET_DIR_PATTERNS+set}" = "set" ] && [ -n "$dir_patterns" ]; then
        printf 'pp_is_secret_file: PP_SECRET_DIR_PATTERNS is whitespace-only; using defaults\n' >&2
        dir_patterns="$dir_defaults"
      fi
      ;;
  esac

  local file_extra="${PP_SECRET_FILE_PATTERNS_EXTRA:-}"
  local dir_extra="${PP_SECRET_DIR_PATTERNS_EXTRA:-}"

  # === Check 1: basename glob match ===
  # Disable pathname expansion during iteration. Otherwise a cwd containing
  # a file like `prod.env` would expand the literal pattern `*.env` into
  # filenames before `case` sees it.
  set -f
  local p
  for p in $file_patterns $file_extra; do
    # shellcheck disable=SC2254  # intentional glob expansion
    case "$base_lc" in
      $p) set +f; return 0 ;;
    esac
  done
  set +f

  # === Check 2: any path component matches a secret-directory glob ===
  # Walk every directory component of $path. Basename is implicitly re-checked
  # against dir patterns here, which is harmless (a file literally named
  # ".ssh" would match, which is fine — almost certainly a secret).
  set -f
  local rest="$path"
  local comp comp_lc
  while [ -n "$rest" ] && [ "$rest" != "/" ] && [ "$rest" != "." ]; do
    comp="${rest##*/}"
    if [ -n "$comp" ]; then
      comp_lc=$(printf '%s' "$comp" | tr '[:upper:]' '[:lower:]')
      for p in $dir_patterns $dir_extra; do
        # shellcheck disable=SC2254  # intentional glob expansion
        case "$comp_lc" in
          $p) set +f; return 0 ;;
        esac
      done
    fi
    # Strip last component. If no '/' remains, we've walked off the front.
    case "$rest" in
      */*) rest="${rest%/*}" ;;
      *)   rest="" ;;
    esac
  done
  set +f

  return 1
}
