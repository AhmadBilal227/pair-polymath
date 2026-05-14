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
