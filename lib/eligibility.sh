#!/usr/bin/env bash
# Pair Polymath — eligibility evaluator (v0.5.1.1, Spec Change 3 / Task 9).
#
# Reads a facts SNAPSHOT (cc-monitor-facts-*.txt) and decides whether
# the given lens has any in-scope surface this cycle. Snapshot is the
# same artifact the lens prompt and the validator see — eligibility is
# the third consumer of the SAME file (snapshot-only, never live FS).
#
# Public function:
#   pp_lens_is_eligible <lens_id> <facts_file>
#     returns 0 — lens has eligible surface (dispatch)
#     returns 1 — lens has NO eligible surface (skip dispatch under gate)
#
# Reads from facts file:
#   - "=== FILE READ (planner picked: <path>) ===" header
#   - "# git_diff_paths" .. "# /git_diff_paths" block
#   - "# git_untracked_paths" .. "# /git_untracked_paths" block
#   - "# git_staged_paths" .. "# /git_staged_paths" block
#
# Snapshot path set = FILE READ ∪ git_diff_paths ∪ git_untracked_paths
#                     ∪ git_staged_paths
#
# Gitless fallback: missing git_* blocks => empty arrays. Snapshot
# path set degenerates to FILE-READ-only. Does NOT crash.
#
# Ignored dirs: stripped before regex pass. Hardcoded set matches spec:
#   node_modules/  .git/  build/  dist/  target/  .cache/
#
# Binary files: dropped via NUL-byte sniff in first 512B (matches the
# FILE-READ block heuristic). If the path doesn't exist on disk (typical
# in tests / archived snapshots) the path is treated as non-binary —
# regex matching proceeds.
#
# Bash 3.2 portable: no mapfile, no extglob, no globstar, no nameref.
# All regex matching uses the bash [[ =~ ]] builtin against the
# pre-cached regex set from lib/lens-loader.sh.

if [ -n "${_PP_ELIGIBILITY_SOURCED:-}" ]; then return 0; fi
_PP_ELIGIBILITY_SOURCED=1

# Hardcoded ignored-dirs list. Tested as a path component anywhere in
# the path string (anchored to '/' on both sides for component match).
_PP_ELIG_IGNORED_DIRS="node_modules .git build dist target .cache"

# _pp_elig_extract_block <facts_file> <header>
# Walks the facts file, emits the body of "# <header>" ... "# /<header>"
# on stdout (newline-delimited; one path per line; blank lines stripped).
# Gitless fallback: missing block => empty stdout + return 0.
_pp_elig_extract_block() {
  local file="$1" header="$2"
  [ -f "$file" ] || return 0
  LC_ALL=C awk -v h="$header" '
    BEGIN { inblock = 0 }
    {
      if ($0 == "# " h)        { inblock = 1; next }
      if ($0 == "# /" h)       { inblock = 0; next }
      if (inblock && length($0) > 0) print $0
    }
  ' "$file" 2>/dev/null
}

# _pp_elig_extract_file_read <facts_file>
# Parses the literal "=== FILE READ (planner picked: <path>) ===" header.
# Emits <path> or empty (when the planner picked NONE / nothing).
_pp_elig_extract_file_read() {
  local file="$1"
  [ -f "$file" ] || return 0
  LC_ALL=C awk '
    /^=== FILE READ \(planner picked:/ {
      sub(/^=== FILE READ \(planner picked: /, "")
      sub(/\) ===.*$/, "")
      if ($0 != "NONE" && $0 != "<none>" && length($0) > 0) print $0
      exit
    }
  ' "$file" 2>/dev/null
}

# _pp_elig_path_in_ignored_dir <path>
# Returns 0 if any path component matches the ignored-dirs list.
# Both leading and arbitrary-depth occurrences ("foo/node_modules/bar")
# are caught by wrapping the path with leading+trailing '/' and matching
# "*/dir/*".
_pp_elig_path_in_ignored_dir() {
  local path="$1" dir
  for dir in $_PP_ELIG_IGNORED_DIRS; do
    case "/$path/" in
      */"$dir"/*) return 0 ;;
    esac
  done
  return 1
}

# _pp_elig_path_is_binary <path>
# Returns 0 if first 512B of the file contains a NUL byte. If the file
# doesn't exist on disk (typical in tests / archived snapshots), return 1
# (NOT binary; let regex matching proceed).
#
# Implementation: byte-count diff before/after `tr -d '\000'`. We can't
# `grep -q $'\x00'` because bash truncates the pattern string at the
# first NUL, leaving grep with an empty pattern that matches every line
# (false-positive binary classification, caught in initial tests).
_pp_elig_path_is_binary() {
  local path="$1"
  [ -f "$path" ] || return 1
  local before after
  before=$(LC_ALL=C head -c 512 "$path" 2>/dev/null | LC_ALL=C wc -c | tr -d ' ')
  after=$(LC_ALL=C head -c 512 "$path" 2>/dev/null | LC_ALL=C tr -d '\000' | LC_ALL=C wc -c | tr -d ' ')
  [ "${before:-0}" != "${after:-0}" ]
}

# pp_lens_is_eligible <lens_id> <facts_file>
#   returns 0 — eligible (lens has in-scope surface this cycle)
#   returns 1 — not eligible (no in-scope surface OR unknown lens)
pp_lens_is_eligible() {
  local lens_id="$1" facts_file="$2"

  # Lazy-source lens-loader if accessors aren't present (lets bin/statusline.sh
  # or test fixtures source us standalone).
  if ! command -v pp_lens_eligibility_kind >/dev/null 2>&1; then
    if [ -n "${PP_ROOT:-}" ] && [ -f "$PP_ROOT/lib/lens-loader.sh" ]; then
      # shellcheck disable=SC1091
      . "$PP_ROOT/lib/lens-loader.sh"
    else
      return 1
    fi
  fi

  local kind
  kind=$(pp_lens_eligibility_kind "$lens_id") || return 1
  if [ "$kind" = "always" ]; then
    return 0
  fi
  if [ "$kind" != "path_glob" ]; then
    # Unknown kind => treat as always-eligible (fail-open). Spec invariant
    # is "no behavior change with PP_LENS_GATES_ACTIVE=0", and a misread
    # lens config should NOT silently disable a lens.
    return 0
  fi

  # Collect path set: FILE READ ∪ git_*. Use newline-delimited
  # accumulator (bash 3.2 — no associative arrays).
  local paths=""
  local fr_path
  fr_path=$(_pp_elig_extract_file_read "$facts_file")
  if [ -n "$fr_path" ]; then
    paths="${fr_path}"$'\n'
  fi
  local block body
  for block in git_diff_paths git_untracked_paths git_staged_paths; do
    body=$(_pp_elig_extract_block "$facts_file" "$block")
    if [ -n "$body" ]; then
      paths="${paths}${body}"$'\n'
    fi
  done

  # No paths at all => not eligible.
  [ -z "$paths" ] && return 1

  # Get the regex set for this lens (one regex per line).
  local regexes
  regexes=$(pp_lens_eligibility_regexes "$lens_id")
  [ -z "$regexes" ] && return 1

  # OR-match. First (path × regex) pair that fires wins.
  local p r
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if _pp_elig_path_in_ignored_dir "$p"; then
      continue
    fi
    if _pp_elig_path_is_binary "$p"; then
      continue
    fi
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      if [[ "$p" =~ $r ]]; then
        return 0
      fi
    done <<EOF
$regexes
EOF
  done <<EOF
$paths
EOF

  return 1
}
