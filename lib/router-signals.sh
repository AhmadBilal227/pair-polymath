#!/usr/bin/env bash
# lib/router-signals.sh — deterministic feature extraction for the
# router meta-lens.
#
# Owns: the transformation from {filtered_transcript, tool_summary_json,
# env vars} → a structured JSON signals object the router LLM (lib/
# router.sh) consumes. No LLM calls happen here. Pure bash + jq + grep.
#
# Public function:
#   pp_router_extract_signals <filtered_transcript> <tool_summary_json>
#     → stdout: JSON object with 8 fields
#
# Output schema (locked by tests):
#   {
#     "phase":                "unknown" | "planning" | "drafting" | "debugging",
#     "confidence":           "low" | "medium" | "high",
#     "outcome":              "unknown" | "test_passed" | "test_failed",
#     "tone":                 "neutral" | "frustrated",
#     "session_age_min":      <int>   (from PP_SESSION_START_EPOCH env)
#     "budget_remaining_pct": <int>   (from PP_BUDGET_REMAINING_PCT env)
#     "last_test_failed":     <bool>  (parallel to outcome, easier to consume)
#     "recent_edit_density":  <int>   (count of recent Edit/Write/MultiEdit calls)
#   }
#
# Env vars consumed (safe defaults if unset):
#   PP_SESSION_START_EPOCH   epoch seconds; session_age_min = (now-start)/60
#   PP_BUDGET_REMAINING_PCT  integer 0-100; default 100
#
# Bash 3.2-portable. LC_ALL=C is scoped per grep/awk call (no global).

if [ -n "${_PP_ROUTER_SIGNALS_SOURCED:-}" ]; then return 0; fi
_PP_ROUTER_SIGNALS_SOURCED=1

# pp_router_extract_signals <filtered_transcript> <tool_summary_json>
pp_router_extract_signals() {
  local _tx="${1:-}"
  local _tools_json="${2:-[]}"

  # Defensive: malformed JSON becomes []. Future Phase 2 router prompt
  # would otherwise see garbage; jq -e gives us a structural check.
  if ! printf '%s' "$_tools_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    _tools_json='[]'
  fi

  # ---------- phase detection ----------
  # Priority: debugging > drafting > planning > unknown. Single-pass
  # heuristics; each axis can be wrong individually but the router LLM
  # gets to disambiguate via the full signals blob.
  local _phase="unknown"
  local _edit_count _read_count _bash_count _test_with_fail

  _edit_count=$(printf '%s' "$_tools_json" | jq '[.[] | select(.tool == "Edit" or .tool == "Write" or .tool == "MultiEdit")] | length' 2>/dev/null)
  _read_count=$(printf '%s' "$_tools_json" | jq '[.[] | select(.tool == "Read")] | length' 2>/dev/null)
  _bash_count=$(printf '%s' "$_tools_json" | jq '[.[] | select(.tool == "Bash")] | length' 2>/dev/null)

  # I3 from GPT plan review: tighten test-failed detection.
  # MUST require: tool == Bash AND target matches test invocation AND
  # summary has FAIL/error markers. A `git push` that errored doesn't
  # count.
  _test_with_fail=$(printf '%s' "$_tools_json" | jq '
    [ .[] | select(.tool == "Bash"
                   and (.target // "" | test("(test|spec|jest|mocha|pytest|go test|pnpm test|npm test|cargo test|bats|rspec)"; "i"))
                   and (.summary // "" | test("(FAIL|ERROR|✗|exit 1|[1-9][0-9]* (failing|failed))"; "i"))
                  )
    ] | length' 2>/dev/null)

  local _plan_hits
  _plan_hits=$(printf '%s' "$_tx" | LC_ALL=C grep -oiE 'let me think|consider the|trade-?off|approach|should we|think about' 2>/dev/null | LC_ALL=C wc -l | tr -d ' \n')

  if [ "${_test_with_fail:-0}" -ge 1 ]; then
    _phase="debugging"
  elif [ "${_edit_count:-0}" -gt "${_read_count:-0}" ] && [ "${_edit_count:-0}" -ge 2 ]; then
    _phase="drafting"
  elif [ "${_plan_hits:-0}" -ge 1 ]; then
    _phase="planning"
  fi

  # ---------- confidence detection ----------
  local _hedges _definites _confidence="medium"
  _hedges=$(printf '%s' "$_tx" | LC_ALL=C grep -oiE 'i think|maybe|perhaps|might|not sure|could be|probably' 2>/dev/null | LC_ALL=C wc -l | tr -d ' \n')
  _definites=$(printf '%s' "$_tx" | LC_ALL=C grep -oiE 'fixed|verified|works|completed|done|tested|confirmed' 2>/dev/null | LC_ALL=C wc -l | tr -d ' \n')
  if [ "${_hedges:-0}" -gt "${_definites:-0}" ] && [ "${_hedges:-0}" -ge 2 ]; then
    _confidence="low"
  elif [ "${_definites:-0}" -gt "${_hedges:-0}" ] && [ "${_definites:-0}" -ge 2 ]; then
    _confidence="high"
  fi

  # ---------- outcome ----------
  # Aligns with phase detection: outcome=test_failed iff a test invocation
  # surfaced a fail marker. test_passed iff a test invocation showed pass
  # markers. Anything else → unknown.
  local _outcome="unknown"
  local _last_test_failed=false
  local _test_with_pass
  _test_with_pass=$(printf '%s' "$_tools_json" | jq '
    [ .[] | select(.tool == "Bash"
                   and (.target // "" | test("(test|spec|jest|mocha|pytest|go test|pnpm test|npm test|cargo test|bats|rspec)"; "i"))
                   and (.summary // "" | test("(PASS|passing|passed|✓|all .* pass)"; "i"))
                  )
    ] | length' 2>/dev/null)

  if [ "${_test_with_fail:-0}" -ge 1 ]; then
    _outcome="test_failed"
    _last_test_failed=true
  elif [ "${_test_with_pass:-0}" -ge 1 ]; then
    _outcome="test_passed"
  fi

  # ---------- tone ----------
  # Frustration ~ 2+ negation markers in user messages (^USER: prefix).
  local _frustration _tone="neutral"
  _frustration=$(printf '%s' "$_tx" | LC_ALL=C grep -oiE '^USER:.*\b(no|wrong|stop|why are you|not working|not getting|that is wrong)\b' 2>/dev/null | LC_ALL=C wc -l | tr -d ' \n')
  if [ "${_frustration:-0}" -ge 2 ]; then
    _tone="frustrated"
  fi

  # ---------- env-derived signals (C1 fix) ----------
  # session_age_min: now - SESSION_START in minutes (0 if env unset).
  local _session_age=0
  if [ -n "${PP_SESSION_START_EPOCH:-}" ]; then
    local _now
    _now=$(date +%s 2>/dev/null)
    [ -z "$_now" ] && _now=0
    if [ "$_now" -gt "$PP_SESSION_START_EPOCH" ]; then
      _session_age=$(( (_now - PP_SESSION_START_EPOCH) / 60 ))
    fi
  fi

  # budget_remaining_pct: env-provided integer 0-100.
  local _budget="${PP_BUDGET_REMAINING_PCT:-100}"
  # Clamp to [0,100] in case caller passed garbage.
  case "$_budget" in
    ''|*[!0-9]*) _budget=100 ;;
  esac
  if [ "$_budget" -gt 100 ]; then _budget=100; fi

  # ---------- recent_edit_density ----------
  local _density="${_edit_count:-0}"

  # ---------- compose JSON ----------
  jq -n \
    --arg phase "$_phase" \
    --arg confidence "$_confidence" \
    --arg outcome "$_outcome" \
    --arg tone "$_tone" \
    --argjson session_age "$_session_age" \
    --argjson budget "$_budget" \
    --argjson density "${_density:-0}" \
    --argjson last_test_failed "$_last_test_failed" \
    '{
      phase: $phase,
      confidence: $confidence,
      outcome: $outcome,
      tone: $tone,
      session_age_min: $session_age,
      budget_remaining_pct: $budget,
      last_test_failed: $last_test_failed,
      recent_edit_density: $density
    }'
}
