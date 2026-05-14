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
