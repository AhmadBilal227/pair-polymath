#!/usr/bin/env bash
# Pair Polymath — deterministic citation extraction. Sourced by bin/statusline.sh.
#
# Phase 2.2: produces explicit path + symbol allowlists from the grounded blob
# so the critique pass can DROP observations citing anything outside the lists.
# Previously the critique LLM had to grep against a truncated 3KB slice of the
# grounded blob — false-positives ate retry budget AND a valid observation
# could be DROPped if the truncation cut off the citation site.
#
# Contract:
#   pp_extract_citations
#     stdin: nothing
#     reads: $grounded  (the assembled grounded blob from statusline.sh)
#     writes (globals):
#       $_pp_valid_paths   — newline-separated paths from path-bearing sections
#                            statusline.sh ACTUALLY emits in production:
#                            GIT STATUS / RECENT DIFF SCOPE / CWD TOP-LEVEL /
#                            RECENT TOOL CALLS / OPEN PRS / RECENT CI RUNS.
#                            (R2 fix: prior list included GIT RECENT FILES and
#                            CWD LISTING — sections statusline.sh never emits —
#                            and pulled from RECENT COMMITS which is SHA+subject
#                            and not actually path-rich. We deliberately exclude
#                            FILE READ — that's for symbols; USER RECENT
#                            MESSAGES + TRANSCRIPT TAIL — free text, possibly
#                            hallucinated paths; PREVIOUS OBSERVATIONS —
#                            semantically circular, would let last cycle's bad
#                            citations pass this cycle's check.)
#       $_pp_valid_symbols — newline-separated identifiers from FILE READ
#                            (matching [A-Za-z_][A-Za-z0-9_]{2,}, stopwords filtered)
#     both capped at 200 entries (memory + prompt-token guard).
#
# Bash 3.2 portable. Each grep/sort/awk call uses LC_ALL=C inline; we do NOT
# set LC_ALL file-globally (the progress-bar tr render in statusline.sh needs
# the user's locale, see PR #25).

# Stopwords filtered out of the symbol allowlist. These are the most common
# tokens that look like identifiers but carry no signal — keeping them in
# pollutes the allowlist (every observation's word is "valid"), so the
# critique check becomes useless. Bash/JS/Python/TS keywords + a handful of
# very common stdlib names (true/false/null/None) and one-character noise.
_PP_CITATION_STOPWORDS="the and for from import export async await function class const let var return if else then elif fi for while do done case esac true false null None None type interface enum public private protected static void int string bool boolean number undefined this self new throw catch try finally yield break continue with end def in is of as or not pass lambda print"

# pp_extract_citations
# Side effect: sets $_pp_valid_paths and $_pp_valid_symbols.
pp_extract_citations() {
  # Default to empty so even on failure the variables are defined (no
  # unbound-var surprises if statusline.sh ever flips `set -u`).
  _pp_valid_paths=""
  _pp_valid_symbols=""

  # `grounded` is sourced from the caller's environment (statusline.sh assembles
  # it just before the analyst fan-out, so it's in scope when the critique
  # block fires). If unset/empty we just emit empty allowlists.
  local blob="${grounded:-}"
  [ -z "$blob" ] && return 0

  # === Paths ===
  # Extract the path-bearing sections via awk (Bash 3.2 has no associative
  # arrays for "section -> include?", but awk does). We include any line that
  # falls between a path-bearing header and the next `=== ` header.
  #
  # Section names MUST match exactly what bin/statusline.sh emits in the
  # grounded blob (search statusline.sh for `=== ` markers around lines
  # 680-720). Header format examples:
  #   `=== GIT STATUS (uncommitted) ===`
  #   `=== RECENT DIFF SCOPE ===`
  #   `=== CWD TOP-LEVEL ===`
  #   `=== RECENT TOOL CALLS (last 15) ===`
  #   `=== OPEN PRS (gh, cached 10min) ===`
  #   `=== RECENT CI RUNS (gh, cached 5min) ===`
  #
  # The section-extraction awk script is small enough that LC_ALL=C inline
  # is portable + cheap. Output is then fed to grep -oE for the actual
  # path tokens.
  local path_sections
  path_sections=$(LC_ALL=C awk '
    /^=== / {
      # Header line. Decide whether we want the BODY that follows.
      include = 0
      if (index($0, "GIT STATUS")        > 0) include = 1
      if (index($0, "RECENT DIFF SCOPE") > 0) include = 1
      if (index($0, "CWD TOP-LEVEL")     > 0) include = 1
      if (index($0, "RECENT TOOL CALLS") > 0) include = 1
      if (index($0, "OPEN PRS")          > 0) include = 1
      if (index($0, "RECENT CI RUNS")    > 0) include = 1
      next
    }
    include == 1 { print }
  ' <<< "$blob")

  # Two path patterns:
  #   - file: token with an extension, e.g. `lib/utils.ts`, `README.md`
  #   - dir : token ending in `/`, e.g. `src/components/`
  # Underscores, dashes, dots, slashes allowed in the body.
  local raw_paths
  raw_paths=$(printf '%s\n' "$path_sections" \
    | LC_ALL=C grep -oE '([a-zA-Z0-9_./-]+\.[a-zA-Z]{1,5}|[a-zA-Z0-9_/-]+/)' 2>/dev/null \
    || true)

  if [ -n "$raw_paths" ]; then
    _pp_valid_paths=$(printf '%s\n' "$raw_paths" \
      | LC_ALL=C sort -u \
      | head -200)
  fi

  # === Symbols ===
  # Extract the FILE READ section body. Header line itself is skipped.
  local file_section
  file_section=$(LC_ALL=C awk '
    /^=== / {
      in_section = 0
      if (index($0, "FILE READ") > 0) in_section = 1
      next
    }
    in_section == 1 { print }
  ' <<< "$blob")

  if [ -n "$file_section" ]; then
    # Symbol regex: identifier-shaped tokens, 3+ chars (matches the spec's
    # `[A-Za-z_][A-Za-z0-9_]{2,}`). grep -oE prints one match per line.
    local raw_symbols
    raw_symbols=$(printf '%s\n' "$file_section" \
      | LC_ALL=C grep -oE '[A-Za-z_][A-Za-z0-9_]{2,}' 2>/dev/null \
      || true)

    if [ -n "$raw_symbols" ]; then
      # Filter stopwords. awk with a SET built from $_PP_CITATION_STOPWORDS.
      # Stopword comparison is case-sensitive on purpose — `Class` and
      # `CLASS` should remain valid symbols if they appear; the stopword
      # list targets the lowercase keyword forms that actually occur in
      # source files. We do however lowercase the input ONLY for the
      # set-lookup, then print the original token, so casing is preserved.
      _pp_valid_symbols=$(printf '%s\n' "$raw_symbols" \
        | LC_ALL=C awk -v stops="$_PP_CITATION_STOPWORDS" '
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
        | LC_ALL=C sort -u \
        | head -200)
    fi
  fi

  return 0
}

# pp_extract_citations_from_text
# Per-observation variant for v0.5.2 SessionEnd schema (C2 fix path A).
#
# Args:
#   $1 — observation body text (no section markers; just a free-form sentence)
# Side effect (globals):
#   $_pp_valid_paths   — newline-separated path tokens found in the text
#   $_pp_valid_symbols — newline-separated identifier tokens, stopword-filtered
#
# Same regex contract as pp_extract_citations (paths: file w/ ext OR dir w/
# trailing slash; symbols: [A-Za-z_][A-Za-z0-9_]{2,} ≥3 chars + stopword-
# filtered). Difference: NO section gating — every token in the input is
# a candidate. Both lists capped at 200.
#
# Used by hooks/session-end.sh to populate cited_paths + cited_symbols in
# the oar-pending row at SessionEnd time, so the v0.5.2 OAR labeler is a
# pure function of the pending row (no filesystem coupling on rotated
# observation files).
#
# MUTUALLY EXCLUSIVE WITH pp_extract_citations: both write the same
# $_pp_valid_paths / $_pp_valid_symbols globals. If you need both call
# results in the same process, save one before calling the other:
#   pp_extract_citations "$grounded_blob"
#   _saved_paths="$_pp_valid_paths"; _saved_syms="$_pp_valid_symbols"
#   pp_extract_citations_from_text "$body"
#   # now $_pp_valid_* are the per-text results
# (Currently safe because the two callers — statusline.sh + session-end.sh —
# run in different processes. Documented for future maintainers.)
pp_extract_citations_from_text() {
  _pp_valid_paths=""
  _pp_valid_symbols=""

  local _text="${1:-}"
  [ -z "$_text" ] && return 0

  # === Paths === (same regex as pp_extract_citations; no section filter)
  local _raw_paths
  _raw_paths=$(printf '%s\n' "$_text" \
    | LC_ALL=C grep -oE '([a-zA-Z0-9_./-]+\.[a-zA-Z]{1,5}|[a-zA-Z0-9_/-]+/)' 2>/dev/null \
    || true)
  if [ -n "$_raw_paths" ]; then
    _pp_valid_paths=$(printf '%s\n' "$_raw_paths" \
      | LC_ALL=C sort -u \
      | head -200)
  fi

  # === Symbols === (same regex + stopword filter as pp_extract_citations)
  local _raw_symbols
  _raw_symbols=$(printf '%s\n' "$_text" \
    | LC_ALL=C grep -oE '[A-Za-z_][A-Za-z0-9_]{2,}' 2>/dev/null \
    || true)
  if [ -n "$_raw_symbols" ]; then
    _pp_valid_symbols=$(printf '%s\n' "$_raw_symbols" \
      | LC_ALL=C awk -v stops="$_PP_CITATION_STOPWORDS" '
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
      | LC_ALL=C sort -u \
      | head -200)
  fi

  return 0
}
