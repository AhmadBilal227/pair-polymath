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
      # Round-3 G1: also check if the BASE itself is a secret dir.
      # If base_real's deepest component matches PP_SECRET_DIR_PATTERNS,
      # everything inside it is suspect — even files with innocuous
      # basenames and shallow cand_rel (e.g. base=/proj/.ssh, candidate=
      # "known_hosts" → cand_rel="known_hosts", which has nothing for the
      # dir-walk to find).
      local _pp_base_last
      _pp_base_last="$(basename -- "$base_real")"
      if pp_is_secret_dir_component "$_pp_base_last"; then
        return 1
      fi
      printf '%s\n' "$cand_real"
      return 0
      ;;
    *) return 1 ;;
  esac
}

# pp_is_secret_dir_component COMPONENT
# Returns 0 if COMPONENT (a single path-component name, e.g. ".ssh" or
# "secrets") matches the active secret-DIRECTORY denylist. Used by
# pp_contain_path to flag the cwd itself being a secret dir.
# Honors the same env-var overrides as pp_is_secret_file:
#   PP_SECRET_DIR_PATTERNS_EXTRA  additive
#   PP_SECRET_DIR_PATTERNS        replace (escape hatch; '' disables)
pp_is_secret_dir_component() {
  local comp="${1:-}"
  [ -z "$comp" ] && return 1

  # Preserve caller's glob state (see Fix N1).
  local _pp_idc_saved_f=0
  case "$-" in *f*) _pp_idc_saved_f=1 ;; esac
  set -f

  local dir_defaults="secrets private .secrets .credentials .keys .aws .ssh"
  local dir_patterns dir_extra
  if [ "${PP_SECRET_DIR_PATTERNS+set}" = "set" ]; then
    dir_patterns="$PP_SECRET_DIR_PATTERNS"
    if [ -z "$dir_patterns" ]; then
      # Round-4 R4-1: parity with pp_is_secret_file Fix G3 — explicit empty
      # PP_SECRET_DIR_PATTERNS disables _EXTRA too (a true off switch).
      dir_extra=""
    else
      dir_extra="${PP_SECRET_DIR_PATTERNS_EXTRA:-}"
    fi
  else
    dir_patterns="$dir_defaults"
    dir_extra="${PP_SECRET_DIR_PATTERNS_EXTRA:-}"
  fi
  # Round-4 R4-4: whitespace-only via [:space:], not just literal space.
  local _trimmed_dir
  _trimmed_dir=$(printf '%s' "$dir_patterns" | tr -d '[:space:]')
  case "$_trimmed_dir" in
    '')
      if [ "${PP_SECRET_DIR_PATTERNS+set}" = "set" ] && [ -n "$dir_patterns" ]; then
        dir_patterns="$dir_defaults"
        dir_extra="${PP_SECRET_DIR_PATTERNS_EXTRA:-}"
      fi
      ;;
  esac

  # Lowercase patterns (Fix G4 parity) and the component.
  local comp_lc patterns_lc extra_lc
  comp_lc=$(printf '%s' "$comp" | tr '[:upper:]' '[:lower:]')
  patterns_lc=$(printf '%s' "$dir_patterns" | tr '[:upper:]' '[:lower:]')
  extra_lc=$(printf '%s' "$dir_extra" | tr '[:upper:]' '[:lower:]')

  local p
  for p in $patterns_lc $extra_lc; do
    # shellcheck disable=SC2254  # intentional glob expansion
    case "$comp_lc" in
      $p)
        [ "$_pp_idc_saved_f" -eq 1 ] || set +f
        return 0
        ;;
    esac
  done

  [ "$_pp_idc_saved_f" -eq 1 ] || set +f
  return 1
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
#
# Contract: pass a RELATIVE path (e.g. "sub/.env"). Absolute inputs get the
# basename check only; the dir-component walk is skipped because absolute
# paths may traverse macOS/Linux system directories (/private/var, /etc) that
# happen to share names with default secret-dir patterns (Fix G2).
#
# Configure:
#   PP_SECRET_FILE_PATTERNS_EXTRA   additive file-basename patterns (user.env)
#   PP_SECRET_FILE_PATTERNS         REPLACE file-basename defaults (escape hatch)
#   PP_SECRET_DIR_PATTERNS_EXTRA    additive directory-name patterns (user.env)
#   PP_SECRET_DIR_PATTERNS          REPLACE directory-name defaults (escape hatch)
# Setting either REPLACE var to '' (explicit empty) disables that check.
# When PP_SECRET_FILE_PATTERNS='' (genuine empty), the corresponding _EXTRA
# is also ignored — empty-string is a full "off" switch (Fix G3). Same for
# PP_SECRET_DIR_PATTERNS / _EXTRA.
# Whitespace-only is treated as user error → defaults + stderr warning.
pp_is_secret_file() {
  local path="${1:-}"
  [ -z "$path" ] && return 1

  # Round-3 N1: preserve caller's noglob state. Without this, unconditional
  # `set +f` at every exit would silently disable the caller's noglob.
  local _pp_isf_saved_f=0
  case "$-" in *f*) _pp_isf_saved_f=1 ;; esac
  set -f

  local base base_lc
  base="$(basename -- "$path")"
  base_lc=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')

  local file_defaults=".env .env.* *.env .envrc *.pem *.key *.p12 *.pfx *credentials* *secrets* *.token *_token *_secret *_apikey authinfo* .netrc id_rsa* id_dsa* id_ecdsa* id_ed25519* *_rsa *_dsa *_ed25519 .npmrc .pypirc service-account*.json *.kubeconfig kubeconfig .git-credentials wp-config.php .aws_credentials .pgpass *.private_key"
  local dir_defaults="secrets private .secrets .credentials .keys .aws .ssh"

  # Distinguish UNSET (use defaults) from EMPTY (use empty list, disabling
  # the check). `${var:-default}` collapses both — `${var+set}` does not.
  local file_patterns dir_patterns file_extra dir_extra
  if [ "${PP_SECRET_FILE_PATTERNS+set}" = "set" ]; then
    file_patterns="$PP_SECRET_FILE_PATTERNS"
    if [ -z "$file_patterns" ]; then
      # Fix G3: explicit empty disables EXTRA too — a true "off" switch.
      file_extra=""
    else
      file_extra="${PP_SECRET_FILE_PATTERNS_EXTRA:-}"
    fi
  else
    file_patterns="$file_defaults"
    file_extra="${PP_SECRET_FILE_PATTERNS_EXTRA:-}"
  fi
  if [ "${PP_SECRET_DIR_PATTERNS+set}" = "set" ]; then
    dir_patterns="$PP_SECRET_DIR_PATTERNS"
    if [ -z "$dir_patterns" ]; then
      # Fix G3 (symmetric): explicit empty disables EXTRA too.
      dir_extra=""
    else
      dir_extra="${PP_SECRET_DIR_PATTERNS_EXTRA:-}"
    fi
  else
    dir_patterns="$dir_defaults"
    dir_extra="${PP_SECRET_DIR_PATTERNS_EXTRA:-}"
  fi

  # Whitespace-only is almost certainly user error — fall back to defaults
  # with a stderr warning. (Genuine empty-string still disables.)
  # Round-4 R4-4: strip ALL whitespace via tr ([:space:]), not just literal
  # space via ${var// /}. Tabs and newlines were previously slipping through.
  local _trimmed_file _trimmed_dir
  _trimmed_file=$(printf '%s' "$file_patterns" | tr -d '[:space:]')
  case "$_trimmed_file" in
    '')
      if [ "${PP_SECRET_FILE_PATTERNS+set}" = "set" ] && [ -n "$file_patterns" ]; then
        printf 'pp_is_secret_file: PP_SECRET_FILE_PATTERNS is whitespace-only; using defaults\n' >&2
        file_patterns="$file_defaults"
        file_extra="${PP_SECRET_FILE_PATTERNS_EXTRA:-}"
      fi
      ;;
  esac
  _trimmed_dir=$(printf '%s' "$dir_patterns" | tr -d '[:space:]')
  case "$_trimmed_dir" in
    '')
      if [ "${PP_SECRET_DIR_PATTERNS+set}" = "set" ] && [ -n "$dir_patterns" ]; then
        printf 'pp_is_secret_file: PP_SECRET_DIR_PATTERNS is whitespace-only; using defaults\n' >&2
        dir_patterns="$dir_defaults"
        dir_extra="${PP_SECRET_DIR_PATTERNS_EXTRA:-}"
      fi
      ;;
  esac

  # Fix G4: lowercase both default and user patterns before glob match.
  # Otherwise PP_SECRET_FILE_PATTERNS_EXTRA="*.PEM" wouldn't match
  # "server.pem" because base_lc is lowercased but the pattern isn't.
  local file_patterns_lc file_extra_lc dir_patterns_lc dir_extra_lc
  file_patterns_lc=$(printf '%s' "$file_patterns" | tr '[:upper:]' '[:lower:]')
  file_extra_lc=$(printf '%s' "$file_extra" | tr '[:upper:]' '[:lower:]')
  dir_patterns_lc=$(printf '%s' "$dir_patterns" | tr '[:upper:]' '[:lower:]')
  dir_extra_lc=$(printf '%s' "$dir_extra" | tr '[:upper:]' '[:lower:]')

  # === Check 1: basename glob match ===
  # Disable pathname expansion during iteration. Otherwise a cwd containing
  # a file like `prod.env` would expand the literal pattern `*.env` into
  # filenames before `case` sees it. (Glob already disabled above.)
  local p
  for p in $file_patterns_lc $file_extra_lc; do
    # shellcheck disable=SC2254  # intentional glob expansion
    case "$base_lc" in
      $p)
        [ "$_pp_isf_saved_f" -eq 1 ] || set +f
        return 0
        ;;
    esac
  done

  # === Check 2: any PARENT-DIR component matches a secret-directory glob ===
  # Fix G2: skip dir-component walk for absolute paths. They may include
  # macOS/Linux system dirs (/private, /etc, etc.) that share names with
  # default secret-dir patterns. Callers should pass a relative path; this
  # is documented in the function contract above. pp_contain_path passes
  # the relative cand_rel already.
  #
  # Round-4 R4-3: walk only PARENT directories, not the path itself. Before
  # this fix, a relative input that was just a basename (e.g. "private",
  # "secrets", ".aws") false-rejected because the loop's first iteration
  # treated the leaf as a dir component. The leaf basename is already
  # checked against file patterns in Check 1; the dir walk's only job is
  # PARENT components. Strip the leaf via `dirname` and walk what's left.
  case "$path" in
    /*) ;;  # Absolute — skip dir walk
    *)
      local rest_dir
      rest_dir="$(dirname -- "$path")"
      case "$rest_dir" in
        .|/|"")
          # No parent dirs to walk (leaf-only path or root) — nothing to check.
          ;;
        *)
          local rest="$rest_dir"
          local comp comp_lc
          while [ -n "$rest" ] && [ "$rest" != "/" ] && [ "$rest" != "." ]; do
            comp="${rest##*/}"
            if [ -n "$comp" ]; then
              comp_lc=$(printf '%s' "$comp" | tr '[:upper:]' '[:lower:]')
              for p in $dir_patterns_lc $dir_extra_lc; do
                # shellcheck disable=SC2254  # intentional glob expansion
                case "$comp_lc" in
                  $p)
                    [ "$_pp_isf_saved_f" -eq 1 ] || set +f
                    return 0
                    ;;
                esac
              done
            fi
            # Strip last component. If no '/' remains, we've walked off the front.
            case "$rest" in
              */*) rest="${rest%/*}" ;;
              *)   rest="" ;;
            esac
          done
          ;;
      esac
      ;;
  esac

  [ "$_pp_isf_saved_f" -eq 1 ] || set +f
  return 1
}
