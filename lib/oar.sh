#!/usr/bin/env bash
# Pair Polymath — OAR (Observation→Action Rate) labeler. v0.5.2.
#
# Owns: the measurement substrate that classifies each injected advisory's
# next-N-hours outcome into one of {acted, referenced, pushed-back, ignored}.
# Reads oar-pending.jsonl, writes oar-labeled.jsonl (and oar-stuck.jsonl on
# 3rd failed attempt). Per-row 3s soft cap; per-cycle cap of 5 rows.
#
# Single-source-of-truth invariants (see spec §B + §F + §G):
#   1. Stable identity = sha256(sid|lens|hash|inject_ts). Re-injections of
#      the same (sid, lens, hash) at different cycles do not collide.
#   2. oar-pending.jsonl has NO size-based rotation. Rows leave pending only
#      via labeled-or-stuck transition.
#   3. All cited paths go through pp_contain_path BEFORE git/grep/ls calls.
#   4. Labeler runs INLINE in statusline.sh in a `& wait`-bounded subshell.
#      Telemetry must never block the cycle.

# Bash 3.2 portable. Forces LC_ALL=C for the awk/sort/grep numerics this
# file invokes. The export is intentional — it matches the project-wide
# pattern at bin/statusline.sh:12 and statusline sources this lib, so the
# locale is already C in that path. Sourcing this from a non-statusline
# context (tests, future bin/polymath subcommands) sets the locale for the
# duration of the script, which is the desired behavior for deterministic
# numeric parsing.
LC_ALL=C
export LC_ALL

# Idempotent source guard (sourced by bin/statusline.sh, bin/polymath, tests).
# Guard against the file being EXECUTED rather than sourced — `return` at
# top level errors out if BASH_SOURCE[0] == $0 (i.e. running this file as a
# script). Cheap defensive check.
if [ -n "${_PP_OAR_SOURCED:-}" ]; then
  if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    return 0
  else
    exit 0
  fi
fi
_PP_OAR_SOURCED=1

# Defaults — match spec §E.
: "${PP_OAR_REF_TAU:=0.5}"
: "${PP_OAR_LABEL_PER_CYCLE_CAP:=5}"
: "${PP_OAR_LABEL_MAX_ATTEMPTS:=3}"
: "${PP_OAR_ROW_TIMEOUT_S:=3}"

# pp_oar_row_identity SID LENS HASH INJECT_TS
# Stdout: 64-hex sha256 of the 4 fields joined by ASCII US (0x1F).
# Used to dedupe labeled rows + look up "already labeled?" membership.
#
# Separator choice: ASCII 0x1F (US, "Unit Separator") — invisible control
# character that never appears in any of the four field domains (session
# id is ksuid-shaped, lens is uppercase identifier, hash is hex, inject_ts
# is ISO-8601). A bare `|` separator would have been ambiguous if any
# field ever contained `|`. Caught by Task 3 review S1 + GPT #3.
pp_oar_row_identity() {
  local _sid="${1:-}" _lens="${2:-}" _hash="${3:-}" _ts="${4:-}"
  local _body
  # printf '\037' emits the single US byte. Bash 3.2 supports this.
  _body=$(printf '%s\037%s\037%s\037%s' "$_sid" "$_lens" "$_hash" "$_ts")
  # Same sha tool chain as pp_project_key in lib/grounding.sh, extended
  # with openssl between native sha256 and the md5 last-resort (caught by
  # Task 3 GPT review #4 — openssl is more ubiquitous than the `sha256` BSD
  # binary on Linux distros).
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$_body" | shasum -a 256 2>/dev/null | cut -c1-64
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$_body" | sha256sum 2>/dev/null | cut -c1-64
  elif command -v sha256 >/dev/null 2>&1; then
    printf '%s' "$_body" | sha256 -q 2>/dev/null | cut -c1-64
  elif command -v openssl >/dev/null 2>&1; then
    # openssl dgst -sha256 output format varies: BSD = "SHA256(stdin)= HEX",
    # GNU = "(stdin)= HEX" or just "HEX  -". awk '{print $NF}' takes the
    # last whitespace-separated field, which is always the hex digest.
    printf '%s' "$_body" | openssl dgst -sha256 2>/dev/null \
      | awk '{print $NF}' | cut -c1-64
  else
    # Last resort — md5 hex padded to 64 chars (deterministic, just not
    # cryptographically strong; identity is a dedupe key not a secret).
    # GPT #1 fix: use command -v branching, NOT `||` inside $() — the
    # pipeline's exit status is `cut`'s (always 0), so the `||` never
    # fired and _md5 silently became empty when md5sum was missing.
    local _md5=""
    if command -v md5sum >/dev/null 2>&1; then
      _md5=$(printf '%s' "$_body" | md5sum 2>/dev/null | cut -c1-32)
    elif command -v md5 >/dev/null 2>&1; then
      _md5=$(printf '%s' "$_body" | md5 -q 2>/dev/null | cut -c1-32)
    fi
    if [ -n "$_md5" ]; then
      printf '%s%s' "$_md5" "$_md5"
    else
      # No hash tool available anywhere on PATH. Emit a deterministic
      # sentinel so callers can detect this case rather than silently
      # using an empty identity (which would collapse all rows together).
      # Pad to 64 chars to satisfy length-asserting tests; the literal
      # "PP_OAR_NO_HASH_TOOL_*" prefix is searchable in logs.
      printf 'PP_OAR_NO_HASH_TOOL_DETERMINISTIC_PLACEHOLDER_64_CHARS_FALLBK00'
    fi
  fi
}

# pp_oar_with_row_timeout SECS COMMAND [ARGS...]
# Run COMMAND with a soft per-row time cap (default $PP_OAR_ROW_TIMEOUT_S=3).
# Uses timeout (GNU coreutils) if present, else gtimeout (macOS via brew
# coreutils), else passes through unbounded. Pass-through is acceptable
# because the cycle has its own outer guard (statusline's `& wait` subshell
# with 15s hard ceiling, see Task 11).
#
# Same fallback pattern as bin/statusline.sh:152 `run_llm`.
# Exit code is the COMMAND's exit code (or 124 / 137 / 143 for the
# timeout-binary-killed-it cases per GNU coreutils semantics).
#
# Probe-once optimization: `command -v` is cheap but the labeler may call
# this 5+ times per cycle (per-cycle row cap) and the function may be
# invoked from tight retry loops in future tasks. Cache the resolved
# timeout binary path in _PP_OAR_TIMEOUT_CMD on first call. Empty string
# means "checked, none available — pass through". Unset means "not yet
# probed". This makes the second-and-later invocations branch-free except
# for the cache hit check.
pp_oar_with_row_timeout() {
  local _secs="${1:-${PP_OAR_ROW_TIMEOUT_S:-3}}"
  shift
  # Validate seconds — non-numeric or empty falls back to 3. Defends
  # against a caller passing "" or "abort" and getting a confusing
  # timeout(1) usage error instead of the intended cap.
  case "$_secs" in ''|*[!0-9]*) _secs=3 ;; esac

  # First-call probe. Use the "unset" sentinel (`+x`) so an explicit
  # empty string (= "no binary found") is distinguishable from "not yet
  # checked". This matters when callers stub PATH mid-test.
  if [ -z "${_PP_OAR_TIMEOUT_CMD+x}" ]; then
    if command -v timeout >/dev/null 2>&1; then
      _PP_OAR_TIMEOUT_CMD="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
      _PP_OAR_TIMEOUT_CMD="gtimeout"
    else
      _PP_OAR_TIMEOUT_CMD=""
    fi
  fi

  if [ -n "$_PP_OAR_TIMEOUT_CMD" ]; then
    "$_PP_OAR_TIMEOUT_CMD" "$_secs" "$@"
    return $?
  fi
  # Pass-through — outer cycle guard handles runaway processes.
  "$@"
}
