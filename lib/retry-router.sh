#!/usr/bin/env bash
# Pair Polymath — cost-aware retry router. v0.5.1 Tier 0.
# Spec: docs/v0.5.1-tier0-spec.md

# pp_retry_classify_reason DROP_REASON_RAW
# Stdout: citation_fail | stale | vague | redundant | format | unknown
pp_retry_classify_reason() {
  local _r="${1:-}"
  case "$(printf '%s' "$_r" | tr '[:upper:]' '[:lower:]')" in
    *citation*|*cite*|*hallucin*|*fabric*|*"not in allowlist"*) printf 'citation_fail' ;;
    *stale*|*"already addressed"*|*"already fixed"*|*outdated*|*"fixed last"*) printf 'stale' ;;
    *vague*|*"no actionable"*|*"investigate further"*|*unspecific*) printf 'vague' ;;
    *redundant*|*"already raised"*|*"duplicate of"*|*"same as"*) printf 'redundant' ;;
    *format*|*malformed*|*"invalid schema"*|*"missing pipe"*) printf 'format' ;;
    *) printf 'unknown' ;;
  esac
}

# pp_retry_confidence REASON_CLASS ALLOWLIST_PATHS_N ALLOWLIST_SYMBOLS_N \
#                     OBS_BODY_LEN LENS_STREAK CONCURRENT_DROPS
# Stdout: high | low
# HIGH iff: citation_fail AND allowlist non-empty AND body>=80 AND concurrent<=2.
# All other paths → LOW (cheap retry on mini model).
pp_retry_confidence() {
  local _class="${1:-unknown}"
  local _paths="${2:-0}"
  local _syms="${3:-0}"
  local _bodylen="${4:-0}"
  local _streak="${5:-0}"
  local _conc="${6:-0}"
  case "$_paths" in ''|*[!0-9]*) _paths=0 ;; esac
  case "$_syms"  in ''|*[!0-9]*) _syms=0  ;; esac
  case "$_bodylen" in ''|*[!0-9]*) _bodylen=0 ;; esac
  case "$_conc"  in ''|*[!0-9]*) _conc=0  ;; esac
  if [ "$_class" = "citation_fail" ] \
     && [ "$(( _paths + _syms ))" -gt 0 ] \
     && [ "$_bodylen" -ge 80 ] \
     && [ "$_conc" -le 2 ]; then
    printf 'high'
    return 0
  fi
  printf 'low'
}

# pp_retry_select_model CONFIDENCE
# Stdout: model name. PP_RETRY_MODEL user-pin wins (escape hatch).
pp_retry_select_model() {
  local _conf="${1:-low}"
  if [ -n "${PP_RETRY_MODEL:-}" ]; then
    printf '%s' "$PP_RETRY_MODEL"
    return 0
  fi
  case "$_conf" in
    high) printf '%s' "${PP_RETRY_MODEL_HIGH:-gpt-5}" ;;
    *)    printf '%s' "${PP_RETRY_MODEL_LOW:-gpt-5-mini}" ;;
  esac
}

# pp_retry_log_shadow JSON_BLOB
# Appends one line to retry-router-shadow.jsonl. Silent fail (telemetry never blocks).
# Gated on PP_RETRY_ROUTER_SHADOW. Rotates at PP_LOG_MAX_BYTES.
pp_retry_log_shadow() {
  [ "${PP_RETRY_ROUTER_SHADOW:-0}" = "1" ] || return 0
  local _blob="${1:-}"
  [ -z "$_blob" ] && return 0
  local _file="${PP_CACHE_DIR:-$HOME/.claude/cache}/retry-router-shadow.jsonl"
  local _max="${PP_LOG_MAX_BYTES:-10485760}"
  case "$_max" in ''|*[!0-9]*) _max=10485760 ;; esac
  mkdir -p "$(dirname "$_file")" 2>/dev/null || return 0
  if [ -f "$_file" ]; then
    local _size
    _size=$(wc -c < "$_file" 2>/dev/null | tr -d ' ')
    if [ "${_size:-0}" -ge "$_max" ]; then
      mv "$_file" "${_file}.1" 2>/dev/null || true
    fi
  fi
  printf '%s\n' "$_blob" >> "$_file" 2>/dev/null || true
}

# pp_retry_canary_bucket SESSION_ID
# Stdout: 0-99 deterministic bucket. Sticky via salted cksum.
pp_retry_canary_bucket() {
  local _sid="${1:?session_id required}"
  local _salt="${PP_RETRY_CANARY_SALT:-pp-canary-v1}"
  LC_ALL=C cksum <<EOF | awk '{print $1 % 100}'
${_sid}|${_salt}
EOF
}

# pp_retry_hard_cap_preflight SESSION_ID MODEL
# Returns 0 (proceed) if the next retry's estimated USD plus the cycle's
# accumulated spend stays within PP_RETRY_USD_PER_CYCLE_HARD_CAP. Returns 1
# (caller should SKIP the retry) if the cap would be exceeded.
#
# Concurrent-safe via mkdir-lock (same pattern as lib/budget.sh + lib/metrics.sh).
# On allow, reserves the estimated spend into the per-cycle spend file so the
# next preflight call sees the new accumulated total.
#
# On lock contention (>50 retries × 20ms ≈ 1s) we fall through to ALLOW rather
# than block the cycle — the hard cap is a soft guardrail, not a correctness
# invariant. Pair this with the daily budget reservation in lib/budget.sh for
# the absolute ceiling.
pp_retry_hard_cap_preflight() {
  [ "${PP_RETRY_HARD_CAP_ENABLE:-0}" = "1" ] || return 0
  local _sid="${1:?session_id required}"
  local _model="${2:?model required}"
  local _cap="${PP_RETRY_USD_PER_CYCLE_HARD_CAP:-0.05}"
  local _spendfile="${PP_CACHE_DIR:-$HOME/.claude/cache}/retry-cycle-spend-${_sid}.txt"
  local _lockfile="${_spendfile}.lock"
  mkdir -p "$(dirname "$_spendfile")" 2>/dev/null || return 0
  local _attempts=0
  while ! mkdir "$_lockfile" 2>/dev/null; do
    _attempts=$((_attempts + 1))
    [ "$_attempts" -gt 50 ] && return 0
    sleep 0.02 2>/dev/null || sleep 1
  done
  local _current
  _current=$(cat "$_spendfile" 2>/dev/null || printf '0')
  case "$_current" in ''|*[!0-9.]*) _current=0 ;; esac
  local _est
  _est=$(pp_metrics_estimate_retry_usd "$_model" 2>/dev/null)
  case "$_est" in ''|*[!0-9.]*) _est=0 ;; esac
  local _would_exceed
  _would_exceed=$(LC_ALL=C awk -v c="$_current" -v e="$_est" -v cap="$_cap" \
    'BEGIN { print ((c + e) > cap) ? 1 : 0 }')
  if [ "$_would_exceed" = "1" ]; then
    rmdir "$_lockfile" 2>/dev/null
    return 1
  fi
  # Reserve the spend so subsequent preflights see this cycle's running total.
  LC_ALL=C awk -v c="$_current" -v e="$_est" 'BEGIN { printf "%.6f", c + e }' \
    > "$_spendfile" 2>/dev/null
  rmdir "$_lockfile" 2>/dev/null
  return 0
}
