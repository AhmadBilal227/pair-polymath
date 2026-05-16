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
  # GPT-review #1 fix: guard the shift. Without this, calling
  # `pp_oar_with_row_timeout` with zero args (relying on env default)
  # triggers "shift: shift count out of range" — fatal under set -e.
  [ $# -gt 0 ] && shift
  # Validate seconds — non-numeric, empty, or zero falls back to 3.
  # Empty/non-numeric: defends against a caller passing "" or "abort"
  # and getting a confusing timeout(1) usage error.
  # Zero: GPT-review #7 — coreutils timeout treats `timeout 0 cmd` as
  # "fire instantly", which produces confusing flakes. Enforce ≥ 1.
  case "$_secs" in
    ''|*[!0-9]*|0) _secs=3 ;;
  esac
  # GPT-review #5: require at least one COMMAND argument. Without this
  # we'd fall through to `timeout SECS` or `$@` (empty), producing a
  # confusing "command not found" or timeout-usage error instead of a
  # clear caller bug message.
  if [ $# -eq 0 ]; then
    printf 'pp_oar_with_row_timeout: no command given\n' >&2
    return 2
  fi

  # First-call probe. Use the "unset" sentinel (`+x`) so an explicit
  # empty string (= "no binary found") is distinguishable from "not yet
  # checked". This matters when callers stub PATH mid-test.
  # GPT-review #3 fix: cache the ABSOLUTE PATH via `type -P` (or the
  # `command -v` fallback) so a later PATH change can't silently switch
  # which binary runs. `type -P` returns the first executable file in
  # PATH matching the name (or empty if none); it's a bash builtin so
  # no fork cost.
  if [ -z "${_PP_OAR_TIMEOUT_CMD+x}" ]; then
    local _probed
    _probed=$(type -P timeout 2>/dev/null || true)
    if [ -n "$_probed" ]; then
      _PP_OAR_TIMEOUT_CMD="$_probed"
    else
      _probed=$(type -P gtimeout 2>/dev/null || true)
      if [ -n "$_probed" ]; then
        _PP_OAR_TIMEOUT_CMD="$_probed"
      else
        _PP_OAR_TIMEOUT_CMD=""
      fi
    fi
  fi

  if [ -n "$_PP_OAR_TIMEOUT_CMD" ]; then
    # GPT-review #2 fix: -k 1 sends SIGKILL one second after SIGTERM if
    # the command ignores TERM. Without this, a stuck command (e.g. a
    # signal-trapping subshell) outlives the wrapper and the outer 15s
    # cycle ceiling becomes the only real guard. coreutils timeout has
    # accepted -k since 8.5 (BusyBox doesn't, but our probe favors the
    # GNU/BSD binaries; -k is harmlessly ignored if unsupported because
    # the binary errors before we'd notice — covered by test).
    "$_PP_OAR_TIMEOUT_CMD" -k 1 "$_secs" "$@"
    return $?
  fi
  # Pass-through — outer cycle guard handles runaway processes.
  "$@"
}

# pp_oar_pushed_back HASH INJECT_TS_EPOCH SCAN_AT_EPOCH
# Spec §B step 2: explicit `polymath dismiss ack <hash-prefix>` only — no
# transcript-negation heuristic (deferred to v0.5.3 per spec §A intentional
# limit; the heuristic version is too noisy without ground-truth labels).
#
# Returns 0 + prints the matching rule's id (so the caller can use it as the
# row's evidence_id) when a dismiss-ack rule satisfies ALL of:
#   - source == "ack"   (NOT manual/auto_suppress — those are different intent)
#   - deleted == false  (latest-line-wins per id, so a disable→enable cycle is honored)
#   - HASH startswith(.hash)  (rule stores the SHORT prefix the user typed;
#                              pending row carries the full hash; comparison
#                              is case-insensitive — applied lowercase to both
#                              per Task 5 GPT-review #7)
#   - .ts (ISO-8601 UTC) within [INJECT_TS_EPOCH, SCAN_AT_EPOCH] inclusive
# Returns 1 (and prints nothing on stdout) otherwise.
#
# SEMANTICS NOTE — state vs event (Task 5 GPT-review #2):
# The spec wording "rule with source=ack ... with created_at falling in
# window" is technically event-based, but this implementation uses
# STATE-BASED semantics: the latest line for each id wins, so a user who
# ack'd then later disabled the ack will NOT be marked pushed-back. The
# choice matches (a) lib/dismiss.sh's authoritative "is this rule active
# now?" model used everywhere else, and (b) test "pushed_back: disabled
# ack does NOT count" which is the load-bearing regression test for this
# function. Event-based semantics would also match the spec but would
# require ignoring the dismiss-subsystem's own deleted=true semantics.
# Revisit if v0.5.3 OAR data shows ack-then-undo cycles are common — for
# now, "currently endorsed by operator at scan time" is the signal we
# want for OAR labeling.
#
# Reads the project-scoped dismiss file via pp_dismiss_file_path — the same
# canonical store pp_dismiss_ack writes to. The spec narrative names this
# `~/.claude/state/dismiss-rules.jsonl`, but the v0.5.0 dismiss subsystem
# uses a project-scoped path (one JSONL per project hash); this function
# delegates to lib/dismiss.sh::pp_dismiss_file_path to stay in lockstep with
# wherever pp_dismiss_ack writes. Schema fields (id/ts/hash/source) match
# pp_dismiss_ack at lib/dismiss.sh:413.
#
# Window is closed on BOTH ends. Caller is responsible for passing
# SCAN_AT_EPOCH = min(now, row.scan_at_epoch) per spec §B.
pp_oar_pushed_back() {
  local _hash="${1:-}"
  local _inj="${2:-0}"
  local _scan="${3:-0}"
  [ -z "$_hash" ] && return 1
  # Defensive validation — non-numeric epoch silently failing would
  # mask a caller bug. Empty string / non-digits → reject.
  case "$_inj" in ''|*[!0-9]*) return 1 ;; esac
  case "$_scan" in ''|*[!0-9]*) return 1 ;; esac
  # Source dismiss.sh on first call. Idempotent (dismiss.sh has no source
  # guard, but redefining the functions is harmless). Use PP_ROOT to locate.
  if ! type pp_dismiss_file_path >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${PP_ROOT:-.}/lib/dismiss.sh" 2>/dev/null || return 1
  fi
  local _rules
  _rules=$(pp_dismiss_file_path 2>/dev/null) || return 1
  [ -f "$_rules" ] || return 1
  # Slurped jq with latest-line-wins fold: honors a disable→enable cycle
  # on the same id (the dismiss subsystem is append-only; the latest line
  # for an id is authoritative — see lib/dismiss.sh:108 group_by/last).
  #
  # GPT-review #4: explicit null filter on ts (was `// 0` which would
  # treat an unparseable timestamp as epoch 0 and accidentally match if
  # the caller passed INJECT_TS_EPOCH=0).
  # GPT-review #7: case-insensitive hash comparison (`ascii_downcase`).
  # User could type uppercase hex (`ABCDEF`) which dismiss.sh stores
  # verbatim; pending rows always carry lowercase. Normalize both sides.
  local _hash_lc
  _hash_lc=$(printf '%s' "$_hash" | tr '[:upper:]' '[:lower:]')
  local _id
  _id=$(jq -s -r --arg h "$_hash_lc" --argjson inj "$_inj" --argjson scan "$_scan" '
    group_by(.id) | map(last)
    | .[]
    | select(.source == "ack")
    | select(.deleted == false)
    | select(.hash != null and .hash != "")
    | (.hash | ascii_downcase) as $p
    | select($h | startswith($p))
    | (.ts | fromdateiso8601?) as $t
    | select($t != null and $t >= $inj and $t <= $scan)
    | .id
  ' "$_rules" 2>/dev/null | head -1)
  [ -n "$_id" ] || return 1
  printf '%s' "$_id"
}
