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

  # GNU realpath (Ubuntu/CI) succeeds for non-existent paths by default;
  # BSD realpath (macOS) fails. We don't use `realpath -e` because BSD
  # realpath doesn't accept that flag. Enforce existence portably here so
  # every caller (lib/oar.sh, lib/hallucination.sh, lib/memory/redact.sh,
  # bin/statusline.sh planner) sees identical semantics: a contained path
  # is one that BOTH (a) lives inside base and (b) exists on disk.
  [ -e "$cand_real" ] || return 1

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

# pp_project_key CWD
# Derives a stable 16-char hex key identifying the project a cwd lives in.
# Used by per-project cache files (TIP_CACHE in bin/statusline.sh) so tips
# generated from project A's CLAUDE.md never leak into project B's view.
#
# Resolution order:
#   1. If CWD is inside a git repo: sha of `git rev-parse --show-toplevel`.
#      All cwds under the same repo collapse to the same key, so working
#      in a subdir doesn't fragment a project's tip cache.
#   2. Otherwise: sha of the cwd itself, after pwd -P realpath resolution.
#   3. Empty/unreadable cwd: 16 chars of '0' (the "unknown project" bucket;
#      degrades to global cache behavior — never silently absent).
#
# Tool chain (review G5): shasum is perl-based and ships on macOS + most
# Linuxes; sha256sum is coreutils (Linux); sha256 is BSD/FreeBSD; md5sum
# is a weak final fallback (cryptographic strength irrelevant — we just
# need stable bucketing). All fallbacks emit hex, so the slice is uniform.
# 16 hex chars (64 bits) instead of 12 (review G6) — cheap reduction in
# birthday collision risk at scale.
pp_project_key() {
  local _cwd="${1:-}"
  [ -z "$_cwd" ] && { printf '0000000000000000'; return 0; }
  [ ! -d "$_cwd" ] && { printf '0000000000000000'; return 0; }

  local _scope=""
  # Prefer git toplevel so subdirs of the same repo share one cache.
  if command -v git >/dev/null 2>&1; then
    _scope=$(git -C "$_cwd" -c core.fsmonitor=false rev-parse --show-toplevel 2>/dev/null)
  fi
  # Fall back to realpath of cwd outside git.
  if [ -z "$_scope" ]; then
    _scope=$(cd "$_cwd" 2>/dev/null && pwd -P) || _scope="$_cwd"
  fi

  local _hash=""
  if command -v shasum >/dev/null 2>&1; then
    _hash=$(printf '%s' "$_scope" | shasum -a 256 2>/dev/null | cut -c1-16)
  elif command -v sha256sum >/dev/null 2>&1; then
    _hash=$(printf '%s' "$_scope" | sha256sum 2>/dev/null | cut -c1-16)
  elif command -v sha256 >/dev/null 2>&1; then
    # BSD/FreeBSD: `sha256 -q` prints just the digest, no filename suffix.
    _hash=$(printf '%s' "$_scope" | sha256 -q 2>/dev/null | cut -c1-16)
  elif command -v md5sum >/dev/null 2>&1; then
    _hash=$(printf '%s' "$_scope" | md5sum 2>/dev/null | cut -c1-16)
  elif command -v md5 >/dev/null 2>&1; then
    # Round-2 review G2-6: macOS lacks shasum/sha256sum/sha256/md5sum on
    # stripped installs but ships /sbin/md5. `md5 -q` prints just the hex.
    _hash=$(printf '%s' "$_scope" | md5 -q 2>/dev/null | cut -c1-16)
  fi
  [ -z "$_hash" ] && _hash="0000000000000000"
  printf '%s' "$_hash"
}

# pp_file_mode PATH
# Stdout: octal permission bits (e.g. "600", "644"). Empty if stat absent
# or PATH unreadable. Single source of truth for cache-permission checks
# in lib/doctor.sh and bin/polymath. (Review fix G1: previously `%Lp` was
# BSD-only; on GNU Linux it returned empty and the check silently skipped.)
pp_file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# pp_safe_git_pathspec PATH
# Stdout: a git-pathspec-safe string suitable for `git ... -- "$out"`.
# The string is prefixed with `:(literal)` magic so git disables its own
# globbing (otherwise a filename like `*.txt` would be interpreted as a
# glob). Trailing slashes on directory inputs are stripped (git treats
# `path/` differently from `path` in --follow).
#
# Caller-quotes contract (C1 from plan addendum, 2026-05-16):
#   The helper returns the raw pathspec bytes (including any embedded
#   apostrophes) WITHOUT POSIX `'\''` escaping. Callers MUST invoke as:
#       git ... -- "$(pp_safe_git_pathspec "$p")"
#   The whole output is one argv element from the shell's double-quoted
#   command substitution, so embedded apostrophes cannot break argv
#   tokenization. Git's `:(literal)` pathspec syntax accepts apostrophes
#   as literal filename characters; no further escaping is required.
#
# Returns 1 with no stdout on:
#   - empty input
#   - leading `-` (option-injection guard)
#   - input that reduces to empty after stripping a trailing slash
# Otherwise returns 0.
#
# Distinct from pp_safe_grep_pattern (which validates grep -E regexes).
# Used by lib/oar.sh::pp_oar_acted_for_path before passing a cited path
# to `git log --follow -- ...` and `git show -M50% -- ...`.
pp_safe_git_pathspec() {
  local p="${1:-}"
  [ -z "$p" ] && return 1
  case "$p" in
    -*) return 1 ;;
  esac
  # Strip a single trailing slash (don't recurse: `path//` becomes `path/`).
  case "$p" in
    */) p="${p%/}" ;;
  esac
  [ -z "$p" ] && return 1
  printf ':(literal)%s' "$p"
}

# pp_grounding_symbol_inventory FACTS_FILE
# v0.5.1.1 Stage A — single source of truth for the FILE-READ-derived
# symbol allowlist. Used by:
#   - bin/statusline.sh validator (VALID SYMBOLS block) — Stage A
#   - bin/statusline.sh prompt (SYMBOL REFERENCE COUNTS, post-Stage C)
# Splitting these two consumers across one helper eliminates the drift
# class the v0.5.1.1 spec calls out as the root of ~70% of lens DROPs.
#
# Input: path to the facts file (the grounded blob; today written by
#   bin/statusline.sh via `pp_write_privacy_log` into
#   $PP_CACHE_DIR/last-cycle-payload.json, but for Stage A this helper
#   accepts ANY file containing a `=== FILE READ: ...===` block — the
#   caller is responsible for choosing the right artifact).
# Output: stopword-filtered, sorted, unique identifiers from the FILE READ
#   block, one per line. Empty stdout + rc=0 when block is missing or
#   contains no identifiers. rc=1 when FACTS_FILE is unreadable.
#
# Identifier regex matches the same shape as citations.sh:
#   [A-Za-z_][A-Za-z0-9_]{2,}     (>=3 chars)
# Stopword set sourced from $_PP_CITATION_STOPWORDS in citations.sh — the
# caller MUST source citations.sh before calling this helper. We do NOT
# re-declare the stopword list here: if it drifts between the two callers
# (this helper vs pp_extract_citations) the validator-side and lens-side
# allowlists will silently disagree — exactly the bug Stage A is fixing.
#
# Bash 3.2 portable: no mapfile, no associative arrays. awk handles
# section extraction (same pattern as lib/citations.sh::pp_extract_citations).
pp_grounding_symbol_inventory() {
  local _facts="${1:-}"
  [ -z "$_facts" ] && return 1
  [ -r "$_facts" ] || return 1

  # === Section extraction ===
  # Grab the body between `=== FILE READ: ...===` (or `=== FILE READ (...) ===`)
  # and the next `=== ` header. The today-grounded blob uses the form
  # `=== FILE READ (planner picked: <path>) ===` (bin/statusline.sh:852)
  # so we match on the `FILE READ` substring per index(), same as
  # pp_extract_citations at lib/citations.sh:109.
  #
  # The canonical "nothing read this cycle" sentinel from
  # bin/statusline.sh:853 — `(no file read this round)` — is skipped
  # explicitly so its own tokens (file/read/round) don't leak into the
  # symbol allowlist. plan-task A2 (pp_grounding_inventory_is_empty)
  # relies on this returning zero symbols for the sentinel input.
  local _section
  _section=$(LC_ALL=C awk '
    /^=== / {
      in_section = 0
      if (index($0, "FILE READ") > 0) in_section = 1
      next
    }
    in_section == 1 {
      if ($0 == "(no file read this round)") next
      print
    }
  ' "$_facts" 2>/dev/null)

  [ -z "$_section" ] && return 0

  # === Identifier extraction ===
  # Identical regex to citations.sh:123 — keeps the two consumers byte-
  # equivalent on the token-extraction step. The downstream stopword
  # filter is also identical (citations.sh:134-144 reproduced below) so
  # the test in step 1 ("drops stopwords") passes whichever way it's
  # invoked.
  local _raw
  _raw=$(printf '%s\n' "$_section" \
    | LC_ALL=C grep -oE '[A-Za-z_][A-Za-z0-9_]{2,}' 2>/dev/null \
    || true)

  [ -z "$_raw" ] && return 0

  # === Stopword filter + sort + uniq ===
  # _PP_CITATION_STOPWORDS comes from lib/citations.sh. If the caller
  # didn't source it (defensive — every production caller does), the awk
  # `stops` arg is empty, the BEGIN loop builds an empty set, and the
  # `tok in stop` check is always false. That degrades to "no stopword
  # filter" — broader allowlist, but not incorrect. We do NOT inline a
  # fallback stopword list here: doing so would silently mask citations.sh
  # being out of date or unsourced.
  # shellcheck disable=SC2154
  printf '%s\n' "$_raw" \
    | LC_ALL=C awk -v stops="${_PP_CITATION_STOPWORDS:-}" '
        BEGIN {
          n = split(stops, arr, " ")
          for (i = 1; i <= n; i++) stop[arr[i]] = 1
        }
        {
          tok = $0
          if (length(tok) < 3) next
          if (tok in stop) next
          print tok
        }
      ' \
    | LC_ALL=C sort -u
  return 0
}

# pp_grounding_inventory_is_empty FACTS_FILE
# v0.5.1.1 Stage A — boolean for the EMPTY-ALLOWLIST EXCEPTION (spec
# task 6b). Returns 0 ("true: inventory is empty, the EXCEPTION fires")
# when pp_grounding_symbol_inventory would produce zero lines; returns 1
# ("false: inventory has entries") otherwise. Missing/unreadable
# FACTS_FILE -> treated as empty (rc=0). Reasoning: an absent snapshot
# means there's nothing for the validator to enforce citations against;
# defaulting to "non-empty" would DROP every observation for citing
# paths/symbols the validator can't check, which inverts the spec's
# intent.
#
# Single source of truth: BOTH the lens prompt (Stage C, will render
# "(no FILE-READ symbols extracted; cite by path only)" when this
# returns 0) and the validator-side critique allowlist block (Stage A,
# renders the EMPTY-ALLOWLIST EXCEPTION clause from prompts/critique.md
# verbatim when this returns 0) call this helper. The bats fixture in
# test/v0.5.1.1-empty-allowlist-mirror.bats pins that both render their
# respective empty-state text driven by this same helper's output.
pp_grounding_inventory_is_empty() {
  local _facts="${1:-}"
  [ -z "$_facts" ] && return 0
  [ -r "$_facts" ] || return 0

  # Reuse the same extractor + filter pipeline. If pp_grounding_symbol_inventory
  # would print nothing, this returns 0 (empty == true). One source of
  # truth: any future change to the extractor automatically flows through
  # this boolean.
  local _out
  _out=$(pp_grounding_symbol_inventory "$_facts" 2>/dev/null)
  if [ -z "$_out" ]; then
    return 0
  fi
  return 1
}

# === v0.5.1.1 Task 2 (Stage C): symbol-block render helpers =================
# Pure transforms; flag-gated at caller level. LC_ALL=C forced everywhere
# (sort/awk) for cross-locale stability (drift_count sha8 invariant).
#
# Three helpers compose into one rendering pipeline:
#   pp_grounding_symbol_inventory_from_file_read FILE_CONTENTS
#     → FILE-READ-derived symbol set (in-memory variant of the facts-file
#       pp_grounding_symbol_inventory above; statusline.sh hands
#       file_contents directly so we can't go via a file path).
#   pp_grounding_render_symbol_block FILE_CONTENTS CWD TOP_N
#     → "name: N refs" lines. Flag OFF = legacy grep block. Flag ON =
#       legacy block filtered to FILE-READ symbols (canonical set).
#       Both modes pass through sort+truncate for deterministic order.
#   pp_grounding_compose_symbol_sections PRIMARY NEARBY
#     → section header(s) + body. Flag OFF = single SYMBOL REFERENCE
#       COUNTS section (byte-identical to pre-Stage-C). Flag ON = primary
#       FILE-READ section + new NEARBY MENTIONS (NOT CITABLE) section.
#
# Drift invariant: prompt-side and validator-side BOTH call
# pp_grounding_symbol_inventory_from_file_read on the same file_contents.
# A divergence in the rendered allowlist would mean the helpers themselves
# disagreed — that's the doctor #22 alarm condition.

# pp_grounding_symbol_inventory_from_file_read FILE_CONTENTS
# Stdout: canonical FILE-READ-derived symbol set, one per line.
# In-memory entry point for the same tokenizer pp_grounding_symbol_inventory
# uses on facts-file input. Drift between the two would break the drift_count
# invariant; both grep regex and sort options must stay byte-identical.
pp_grounding_symbol_inventory_from_file_read() {
  local _file_contents="${1:-}"
  [ -z "$_file_contents" ] && return 0
  printf "%s" "$_file_contents" \
    | LC_ALL=C grep -oE '(^|[[:space:]])(function|const|let|class|def)[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]+' 2>/dev/null \
    | LC_ALL=C awk '{print $NF}' \
    | LC_ALL=C sort -u
}

# pp_grounding_sort_and_truncate TOP_N
# stdin: "name: N refs" lines (legacy symbol_refs format from statusline.sh).
# stdout: top TOP_N, sorted freq DESC + ASCII tie-break ASC. Appends
#         "(+N more — pull via FILE READ to cite)" when input rows > TOP_N.
pp_grounding_sort_and_truncate() {
  local _n="${1:-80}"
  case "$_n" in ''|*[!0-9]*) _n=80 ;; esac
  # Read stdin into a temp file so we can count + sort + truncate.
  local _tmp
  _tmp=$(mktemp 2>/dev/null) || return 0
  cat > "$_tmp"
  local _total
  # grep -c with no match exits 1 and prints 0; `|| true` suppresses
  # exit-1 propagation under `set -e`.
  _total=$(LC_ALL=C grep -c ':' "$_tmp" 2>/dev/null || true)
  case "$_total" in ''|*[!0-9]*) _total=0 ;; esac
  # Sort key 1: refs count DESC (numeric). Sort key 2: symbol name ASC (lex).
  # Awk projects each row to "<freq>\t<name>\toriginal-line"; sort -k1nr -k2
  # over the projection; cut restores the original line. LC_ALL=C pins the
  # collation so 'DeltaThing' < 'gamma' (capital before lowercase, ASCII).
  LC_ALL=C awk -F': *' '
    NF >= 2 {
      sym = $1
      refs = $2
      gsub(/ refs.*$/, "", refs)
      gsub(/^[ \t]+|[ \t]+$/, "", sym)
      gsub(/^[ \t]+|[ \t]+$/, "", refs)
      if (sym == "" || refs !~ /^[0-9]+$/) next
      printf "%s\t%s\t%s\n", refs, sym, $0
    }
  ' "$_tmp" \
    | LC_ALL=C sort -t '	' -k1,1nr -k2,2 \
    | head -n "$_n" \
    | cut -f3-
  if [ "$_total" -gt "$_n" ]; then
    local _extra=$((_total - _n))
    printf '(+%s more — pull via FILE READ to cite)\n' "$_extra"
  fi
  rm -f "$_tmp" 2>/dev/null || true
}

# pp_grounding_render_symbol_block FILE_CONTENTS CWD TOP_N
# Flag OFF (default) ⇒ legacy grep block, then sort+truncate (deterministic
# order; bounded by TOP_N). Flag ON ⇒ filter legacy rows to symbols that
# ALSO appear in the FILE-READ canonical set; grep frequency still drives
# the sort key.
pp_grounding_render_symbol_block() {
  local _file_contents="${1:-}"
  local _cwd="${2:-}"
  local _n="${3:-80}"
  case "$_n" in ''|*[!0-9]*) _n=80 ;; esac
  [ -z "$_file_contents" ] && return 0
  if [ -z "$_cwd" ] || [ "$_cwd" = "-" ]; then
    return 0
  fi

  # Reproduce statusline.sh's legacy grep-derived symbol_refs computation
  # here so the rendering pipeline has one source of truth. Do NOT change
  # the underlying extraction; only filter / sort / truncate downstream.
  local _candidates _legacy_block
  _candidates=$(printf "%s" "$_file_contents" \
    | LC_ALL=C grep -oE '(^|[[:space:]])(function|const|let|class|def)[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]+' 2>/dev/null \
    | LC_ALL=C awk '{print $NF}' | LC_ALL=C sort -u | head -15)
  _legacy_block=""
  if [ -n "$_candidates" ]; then
    local _sym _refs
    while IFS= read -r _sym; do
      [ -z "$_sym" ] && continue
      _refs=$(LC_ALL=C grep -rn -F --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
                --include='*.py' --include='*.go' --include='*.rs' \
                --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist \
                --exclude-dir=build --exclude-dir=coverage --exclude-dir=.next \
                --exclude-dir=.turbo --exclude-dir=vendor \
                -- "$_sym" "$_cwd" 2>/dev/null | wc -l | tr -d ' ')
      case "$_refs" in ''|*[!0-9]*) _refs=0 ;; esac
      if [ "$_refs" -gt 0 ]; then
        _legacy_block="${_legacy_block}${_sym}: ${_refs} refs"$'\n'
      fi
    done <<EOF
$_candidates
EOF
  fi

  if [ "${PP_INVENTORY_UNIFY_ACTIVE:-0}" != "1" ]; then
    # Legacy path — emit grep block as-is via sort_and_truncate (still
    # deterministic; still bounded to TOP_N for token-cost predictability).
    printf '%s' "$_legacy_block" | pp_grounding_sort_and_truncate "$_n"
    return 0
  fi

  # Flag ON — filter the legacy block to symbols that ALSO appear in the
  # FILE-READ-derived canonical inventory.
  local _canonical
  _canonical=$(pp_grounding_symbol_inventory_from_file_read "$_file_contents" 2>/dev/null \
                 | LC_ALL=C sort -u)
  if [ -z "$_canonical" ]; then
    # FILE-READ inventory empty — let the caller render the explicit
    # empty-state string via compose_symbol_sections (Task 6b).
    return 0
  fi
  # Pass canonical set via a temp file rather than -v: awk's -v parser
  # rejects embedded newlines on mawk/some macOS awks ("awk: newline in
  # string"). The temp file is read once in BEGIN, then closed before
  # the per-record loop scans stdin.
  local _canon_tmp
  _canon_tmp=$(mktemp 2>/dev/null) || return 0
  printf '%s\n' "$_canonical" > "$_canon_tmp"
  printf '%s' "$_legacy_block" \
    | LC_ALL=C awk -F': *' -v canon_file="$_canon_tmp" '
        BEGIN {
          while ((getline line < canon_file) > 0) {
            if (line != "") ok[line] = 1
          }
          close(canon_file)
        }
        NF >= 2 && ($1 in ok) { print $0 }
      ' \
    | pp_grounding_sort_and_truncate "$_n"
  rm -f "$_canon_tmp" 2>/dev/null || true
}

# pp_grounding_compose_symbol_sections PRIMARY_BLOCK NEARBY_BLOCK
# Flag OFF ⇒ only "=== SYMBOL REFERENCE COUNTS (grep across cwd) ===" header
#   + PRIMARY_BLOCK (or legacy default sentinel when empty). NEARBY_BLOCK
#   ignored. Byte-identical (post-command-sub trim) to pre-Stage-C heredoc.
# Flag ON ⇒ "=== SYMBOL REFERENCE COUNTS (FILE-READ-derived — citable) ==="
#   + PRIMARY_BLOCK (or empty-state sentinel), then "=== NEARBY MENTIONS
#   (NOT CITABLE — read the file first to cite) ===" + NEARBY_BLOCK.
#
# Output contract: no trailing newline. Caller embeds via `${var}` inside
# a heredoc, which adds its own \n. Internal section separators do emit
# a blank line (\n\n between primary and nearby sections, flag on only).
pp_grounding_compose_symbol_sections() {
  local _primary="${1:-}"
  local _nearby="${2:-}"
  # Strip any trailing newline from inputs so we have exact control over
  # output framing.
  _primary="${_primary%$'\n'}"
  _nearby="${_nearby%$'\n'}"
  if [ "${PP_INVENTORY_UNIFY_ACTIVE:-0}" != "1" ]; then
    printf '=== SYMBOL REFERENCE COUNTS (grep across cwd) ===\n'
    if [ -n "$_primary" ]; then
      printf '%s' "$_primary"
    else
      printf '(no symbols extracted from file read)'
    fi
    return 0
  fi
  printf '=== SYMBOL REFERENCE COUNTS (FILE-READ-derived — citable) ===\n'
  if [ -n "$_primary" ]; then
    printf '%s\n' "$_primary"
  else
    printf '(no FILE-READ symbols extracted; cite by path only)\n'
  fi
  printf '\n=== NEARBY MENTIONS (NOT CITABLE — read the file first to cite) ===\n'
  if [ -n "$_nearby" ]; then
    printf '%s' "$_nearby"
  else
    printf '(no nearby grep hits in cwd)'
  fi
}
