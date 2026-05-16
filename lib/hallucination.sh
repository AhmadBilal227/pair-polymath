#!/usr/bin/env bash
# Pair Polymath — hallucination gate post-check. v0.5.2.
# Spec: docs/v0.5.2-oar-hallucination-spec.md §C.
# Plan: docs/superpowers/plans/2026-05-15-v0.5.2-oar-hallucination.md Task 9.
#
# Owns: a single function — pp_halluc_verify_citations — which deterministically
# re-checks an observation's cited paths and symbols using STRICTER rules than
# the critique LLM's allowlist. Used by bin/statusline.sh as a shadow post-check
# AFTER critique PASS. The function is PURE:
#   * No globals mutated.
#   * No files written.
#   * No verdict flipped.
# The caller decides whether to ACT on the rc=1 result (only when
# PP_HALLUC_GATE_ACTIVE=1; default off). This separation is load-bearing:
# v0.5.2 ships in SHADOW MODE so the post-check's FPR can be measured against
# OAR's denominator BEFORE the verdict is allowed to flip. See spec §C
# "Critical change from v2".
#
# Algorithm (spec §C, plan Task 9):
#   1. Empty citations → trivially rc=0 (no-citation observations are NOT
#      hallucination targets — they have nothing to verify).
#   2. For each cited path:
#      a. pp_contain_path against CWD. Outside cwd / unresolvable → rc=1.
#      b. (Containment already verifies the path canonicalises, which on
#         realpath(1) requires the target to exist.)
#   3. For each cited symbol (min length 4 — matches spec §B acted check's
#      min length to keep "strict vs strict" symmetry):
#      a. Word-boundary grep (`grep -wF`) across the contained cited paths.
#      b. If PP_HALLUC_GATE_DEEP=1, fall back to the project-root `tags` file
#         (universal-ctags / exuberant-ctags shared format: TAB-separated,
#         field 1 = symbol). Gracefully degrades if tags is absent.
#   4. Both checks pass → rc=0. Any miss → rc=1.

# Bash 3.2 portable. Forces LC_ALL=C to keep grep/awk numeric + collation
# deterministic — same pattern as lib/oar.sh.
LC_ALL=C
export LC_ALL

# Idempotent source guard. Guard against being EXECUTED (not sourced): `return`
# at top level errors out when this file is the entry point — fall back to exit.
if [ -n "${_PP_HALLUC_SOURCED:-}" ]; then
  if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    return 0
  else
    exit 0
  fi
fi
_PP_HALLUC_SOURCED=1

# Lazy-source grounding.sh for pp_contain_path. Same pattern as lib/oar.sh:48
# (plan addendum I1 — tests intentionally do NOT pre-source grounding so the
# runtime gap is caught here, not masked by harness setup).
if ! type pp_contain_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}/lib/grounding.sh" 2>/dev/null || true
fi

# Minimum symbol length to be considered a real (non-stopword) citation.
# Matches spec §B's acted-check stopword/length floor. Citations shorter than
# this are unverifiable post-hoc — treat as fabricated for hallucination's
# purposes (the LLM should not be citing 1-3-char symbols anyway).
: "${_PP_HALLUC_MIN_SYM_LEN:=4}"

# pp_halluc_verify_citations CWD BODY CITED_PATHS_NL CITED_SYMS_NL
#
# Args:
#   CWD             — absolute path; the cwd at observation-cycle time. All
#                     cited paths are resolved relative to this and required
#                     to be contained inside it.
#   BODY            — observation text. Currently unused (reserved for future
#                     borderline heuristics — kept in the signature so callers
#                     don't have to refactor when v0.5.3 wires it in).
#   CITED_PATHS_NL  — newline-separated list of cited paths (empty allowed).
#   CITED_SYMS_NL   — newline-separated list of cited symbols (empty allowed).
#
# Returns:
#   0 — every citation verifies (would-PASS).
#   1 — at least one citation fails the strict check (would-DROP).
#
# Side effects: NONE. The function writes nothing, mutates nothing, prints
# nothing on stdout. This is load-bearing — see the file-level comment about
# the OAR measurement denominator.
pp_halluc_verify_citations() {
  local _cwd="${1:-}" _body _paths="${3:-}" _syms="${4:-}"
  _body="${2:-}"   # currently unused; kept in signature for v0.5.3.

  # _body is intentionally a no-op assignment in v0.5.2. Reference it so
  # the linter does not warn about unused params (and to document intent).
  : "$_body"

  [ -n "$_cwd" ] || return 1
  [ -d "$_cwd" ] || return 1

  # === Step 1: empty inputs → trivially PASS ===
  if [ -z "$_paths" ] && [ -z "$_syms" ]; then
    return 0
  fi

  # === Step 2: cited paths — contain + canonicalise ===
  # Collect the resolved (real) paths so symbol-grep targets canonical files,
  # not the user's literal cite strings.
  local _p _contained _resolved_paths=""
  if [ -n "$_paths" ]; then
    while IFS= read -r _p || [ -n "$_p" ]; do
      [ -z "$_p" ] && continue
      # pp_contain_path: stdout = resolved real path on success; rc=1 on
      # traversal / missing target / cwd-escape. realpath inside the helper
      # implicitly verifies the path exists on disk.
      _contained=$(pp_contain_path "$_cwd" "$_p" 2>/dev/null) || return 1
      [ -n "$_contained" ] || return 1
      _resolved_paths="${_resolved_paths}${_contained}"$'\n'
    done <<< "$_paths"
  fi

  # === Step 3: cited symbols — word-boundary match ===
  local _s _found
  if [ -n "$_syms" ]; then
    while IFS= read -r _s || [ -n "$_s" ]; do
      [ -z "$_s" ] && continue

      # Min-length floor. Spec §B uses this for the acted check; we apply
      # the same floor here (post-check must be at least as strict).
      if [ "${#_s}" -lt "${_PP_HALLUC_MIN_SYM_LEN}" ]; then
        return 1
      fi

      _found=0

      # 3a — word-boundary grep across the resolved cited paths.
      # Use grep -wF (fixed-string, word-boundary). -F neutralises regex
      # metacharacters in the symbol; -w enforces token boundaries so
      # `handleRetry` does NOT match inside `handleRetryQueueDispatcher`.
      if [ -n "$_resolved_paths" ]; then
        local _rp
        while IFS= read -r _rp || [ -n "$_rp" ]; do
          [ -z "$_rp" ] && continue
          [ -f "$_rp" ] || continue
          if LC_ALL=C grep -wF -q -- "$_s" "$_rp" 2>/dev/null; then
            _found=1
            break
          fi
        done <<< "$_resolved_paths"
      fi

      # 3b — DEEP=1 ctags fallback. The tags file lives at <cwd>/tags by
      # convention (universal-ctags / exuberant-ctags default output path).
      # If not present OR not readable, fallback silently no-ops and the
      # symbol stays unverified → rc=1. We intentionally do NOT shell out
      # to ctags here (would mutate the cwd by creating a tags file); the
      # tags file is read-only consumed.
      if [ "$_found" = "0" ] && [ "${PP_HALLUC_GATE_DEEP:-0}" = "1" ]; then
        if [ -r "$_cwd/tags" ]; then
          # Tag file format (universal-ctags default): TAB-separated,
          # field 1 = symbol name. `$1 == s` is an EXACT match (no
          # word-boundary fuzz needed — the field is already tokenised).
          if LC_ALL=C awk -v s="$_s" -F'\t' \
              '$1 == s { found=1; exit } END { exit !found }' \
              "$_cwd/tags" >/dev/null 2>&1; then
            _found=1
          fi
        fi
      fi

      [ "$_found" = "1" ] || return 1
    done <<< "$_syms"
  fi

  return 0
}
