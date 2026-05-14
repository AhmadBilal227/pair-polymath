#!/usr/bin/env bash
# v0.5.1 — Auto-rollback state machine for retry router.
#
# When the retry router misbehaves (drop-rate regression, cost overrun, error
# spike) the supervisor engages a rollback flag with a TTL (24h initial, 72h
# repeat, 168h on third+ offense within 30d). While the flag is active and
# unexpired, the router falls back to v0.5.0 behavior.
#
# Files:
#   $PP_STATE_DIR/retry-router-disabled.flag  — single line: epoch expiry
#   $PP_STATE_DIR/retry-router-rollback.json  — {disable_count, last_engage_ts}

_pp_rollback_state_file() {
  printf '%s' "${PP_STATE_DIR:-$HOME/.claude/pair-polymath}/retry-router-rollback.json"
}

_pp_rollback_flag_file() {
  printf '%s' "${PP_STATE_DIR:-$HOME/.claude/pair-polymath}/retry-router-disabled.flag"
}

pp_rollback_is_active() {
  local _flag
  _flag=$(_pp_rollback_flag_file)
  [ -f "$_flag" ] || return 1
  # Check expiry timestamp inside flag file
  local _expires_ts
  _expires_ts=$(head -1 "$_flag" 2>/dev/null)
  case "$_expires_ts" in ''|*[!0-9]*) return 1 ;; esac
  local _now
  _now=$(date +%s)
  [ "$_expires_ts" -gt "$_now" ]
}

pp_rollback_engage() {
  local _hours="${1:-24}"
  local _flag _now _expires
  _flag=$(_pp_rollback_flag_file)
  _now=$(date +%s)
  _expires=$(( _now + _hours * 3600 ))
  mkdir -p "$(dirname "$_flag")" 2>/dev/null
  printf '%d\n' "$_expires" > "$_flag"
  # Increment state.disable_count
  local _state
  _state=$(_pp_rollback_state_file)
  local _count=0
  if [ -f "$_state" ]; then
    _count=$(jq -r '.disable_count // 0' "$_state" 2>/dev/null || echo 0)
  fi
  _count=$((_count + 1))
  jq -nc --argjson c "$_count" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{disable_count: $c, last_engage_ts: $ts}' > "$_state"
}

pp_rollback_clear() {
  rm -f "$(_pp_rollback_flag_file)" 2>/dev/null || true
}

pp_rollback_next_backoff_hours() {
  local _state
  _state=$(_pp_rollback_state_file)
  local _count=0
  if [ -f "$_state" ]; then
    _count=$(jq -r '.disable_count // 0' "$_state" 2>/dev/null || echo 0)
  fi
  case "$_count" in
    0)   printf '%d' "${PP_RETRY_BACKOFF_INITIAL_HOURS:-24}" ;;
    1)   printf '%d' "${PP_RETRY_BACKOFF_REPEAT_HOURS:-72}" ;;
    *)   printf '%d' "${PP_RETRY_BACKOFF_MAX_HOURS:-168}" ;;
  esac
}

# pp_rollback_check_and_engage
# B2 (v0.5.1): the SLO evaluator. Reads kpi-cycle.jsonl, computes the
# rolling-PP_RETRY_SLO_WINDOW_HOURS p95 of retry_usd over eligible cycles,
# and engages the rollback flag (with the backoff TTL) if the SLO is
# breached. Wired into bin/statusline.sh at cycle-end, gated on
# PP_RETRY_ROUTER_ENABLE=1.
#
# Eligibility (v0.5.1 simplified per spec Section H): a cycle is eligible
# iff PP_RETRY_MODEL is NOT user-pinned (escape-hatch sessions excluded).
# This is a coarse, whole-run gate for v0.5.1; the per-cycle heavy-task
# token filter is deferred to v0.5.2 alongside OAR.
#
# Breach condition: eligible_count >= PP_RETRY_SLO_MIN_SAMPLES
#   AND p95(retry_usd) > PP_RETRY_SLO_P95_CAP_USD.
#
# Runs in the cycle hot path — kept cheap (one jq count + one jq+awk p95
# over a single bounded JSONL). Fails open: any error → return 0, no
# engage, never block the cycle.
pp_rollback_check_and_engage() {
  # Already disabled → nothing to do (don't re-engage / extend on every cycle).
  pp_rollback_is_active 2>/dev/null && return 0

  # Eligibility gate: a user-pinned PP_RETRY_MODEL means this run is an
  # escape-hatch session — exclude it from SLO evaluation entirely.
  [ -n "${PP_RETRY_MODEL:-}" ] && return 0

  local _window_h="${PP_RETRY_SLO_WINDOW_HOURS:-24}"
  case "$_window_h" in ''|*[!0-9]*) _window_h=24 ;; esac
  local _min_samples="${PP_RETRY_SLO_MIN_SAMPLES:-20}"
  case "$_min_samples" in ''|*[!0-9]*) _min_samples=20 ;; esac
  local _cap="${PP_RETRY_SLO_P95_CAP_USD:-0.030}"

  local _file="${PP_CACHE_DIR:-$HOME/.claude/cache}/kpi-cycle.jsonl"
  [ -f "$_file" ] || return 0

  local _now _cutoff
  _now=$(date +%s 2>/dev/null) || return 0
  _cutoff=$(( _now - _window_h * 3600 ))

  # Count eligible cycles in the window (current + rotated file).
  local _count
  _count=$(cat "${_file}.1" "$_file" 2>/dev/null \
    | jq -s --argjson cutoff "$_cutoff" '
        [ .[] | select((.ts | fromdateiso8601? // 0) >= $cutoff) ] | length
      ' 2>/dev/null)
  case "$_count" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_count" -ge "$_min_samples" ] || return 0

  # p95 of retry_usd over the window. pp_kpi_compute_p95 lives in
  # lib/metrics.sh; guard for standalone sourcing.
  command -v pp_kpi_compute_p95 >/dev/null 2>&1 || return 0
  local _p95
  _p95=$(pp_kpi_compute_p95 retry_usd "$_window_h" 2>/dev/null)
  case "$_p95" in ''|*[!0-9.]*) return 0 ;; esac

  local _breach
  _breach=$(LC_ALL=C awk -v p="$_p95" -v cap="$_cap" \
    'BEGIN { print (p > cap) ? 1 : 0 }' 2>/dev/null)
  if [ "$_breach" = "1" ]; then
    local _hours
    _hours=$(pp_rollback_next_backoff_hours 2>/dev/null)
    case "$_hours" in ''|*[!0-9]*) _hours=24 ;; esac
    pp_rollback_engage "$_hours" 2>/dev/null || true
  fi
  return 0
}
