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

# Bash 3.2 portable. Forces LC_ALL=C for the awk/sort/grep numerics in this
# file only; the rest of the project respects the caller's locale.
LC_ALL=C
export LC_ALL

# Idempotent source guard (sourced by bin/statusline.sh, bin/polymath, tests).
if [ -n "${_PP_OAR_SOURCED:-}" ]; then return 0; fi
_PP_OAR_SOURCED=1

# Defaults — match spec §E.
: "${PP_OAR_REF_TAU:=0.5}"
: "${PP_OAR_LABEL_PER_CYCLE_CAP:=5}"
: "${PP_OAR_LABEL_MAX_ATTEMPTS:=3}"
: "${PP_OAR_ROW_TIMEOUT_S:=3}"

# pp_oar_row_identity SID LENS HASH INJECT_TS
# Stdout: 64-hex sha256 of the 4 fields joined by '|'.
# Used to dedupe labeled rows + look up "already labeled?" membership.
pp_oar_row_identity() {
  local _sid="${1:-}" _lens="${2:-}" _hash="${3:-}" _ts="${4:-}"
  local _body
  _body=$(printf '%s|%s|%s|%s' "$_sid" "$_lens" "$_hash" "$_ts")
  # Same sha tool chain as pp_project_key in lib/grounding.sh (G5/G6).
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$_body" | shasum -a 256 2>/dev/null | cut -c1-64
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$_body" | sha256sum 2>/dev/null | cut -c1-64
  elif command -v sha256 >/dev/null 2>&1; then
    printf '%s' "$_body" | sha256 -q 2>/dev/null | cut -c1-64
  else
    # Last resort — md5 hex padded to 64 chars (deterministic, just not
    # cryptographically strong; identity is a dedupe key not a secret).
    local _md5
    _md5=$(printf '%s' "$_body" | md5sum 2>/dev/null | cut -c1-32 \
        || printf '%s' "$_body" | md5 -q 2>/dev/null | cut -c1-32)
    printf '%s%s' "$_md5" "$_md5"
  fi
}
