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
  local _phase_source="unknown"
  local _edit_count _read_count _bash_count _test_with_fail _test_with_pass

  _edit_count=$(printf '%s' "$_tools_json" | jq '[.[] | select(.tool == "Edit" or .tool == "Write" or .tool == "MultiEdit")] | length' 2>/dev/null)
  _read_count=$(printf '%s' "$_tools_json" | jq '[.[] | select(.tool == "Read")] | length' 2>/dev/null)
  _bash_count=$(printf '%s' "$_tools_json" | jq '[.[] | select(.tool == "Bash")] | length' 2>/dev/null)

  # I3 from GPT plan review: tighten test-failed detection.
  # MUST require: tool == Bash AND target matches test invocation AND
  # summary has FAIL/error markers. A `git push` that errored doesn't
  # count.
  _test_with_fail=$(printf '%s' "$_tools_json" | jq '
    [ .[] | select(.tool == "Bash"
                   and (.target // "" | test("(test|spec|jest|mocha|vitest|pytest|playwright|cypress|go test|pnpm test|npm test|cargo test|bats|rspec|nx (test|e2e))"; "i"))
                   and (.summary // "" | test("(FAIL|ERROR|✗|exit 1|[1-9][0-9]* (failing|failed))"; "i"))
                  )
    ] | length' 2>/dev/null)
  # _test_with_pass is also computed in the outcome block below — we hoist
  # the same query here so the v0.5.1 F1-F7 fallback can use it before the
  # JSON emit. Same predicate to keep behavior identical.
  _test_with_pass=$(printf '%s' "$_tools_json" | jq '
    [ .[] | select(.tool == "Bash"
                   and (.target // "" | test("(test|spec|jest|mocha|vitest|pytest|playwright|cypress|go test|pnpm test|npm test|cargo test|bats|rspec|nx (test|e2e))"; "i"))
                   and (.summary // "" | test("(PASS|passing|passed|✓|all .* pass)"; "i"))
                  )
    ] | length' 2>/dev/null)

  local _plan_hits
  # AI-eng I2: bare 'approach' fires on "my approach to caching".
  # Dropped; planning markers must be meta-discussion phrases.
  _plan_hits=$(printf '%s' "$_tx" | LC_ALL=C grep -oiE 'let me think|consider the|trade-?off|should we|think about|let.?s plan' 2>/dev/null | LC_ALL=C wc -l | tr -d ' \n')

  if [ "${_test_with_fail:-0}" -ge 1 ]; then
    _phase="debugging"
    _phase_source="pattern"
  elif [ "${_edit_count:-0}" -gt "${_read_count:-0}" ] && [ "${_edit_count:-0}" -ge 2 ]; then
    _phase="drafting"
    _phase_source="pattern"
  elif [ "${_plan_hits:-0}" -ge 1 ]; then
    _phase="planning"
    _phase_source="pattern"
  fi

  # ---------- confidence detection ----------
  local _hedges _definites _confidence="medium"
  _hedges=$(printf '%s' "$_tx" | LC_ALL=C grep -oiE '\b(i think|maybe|perhaps|might|not sure|could be|probably)\b' 2>/dev/null | LC_ALL=C wc -l | tr -d ' \n')
  # AI-eng M3: word boundaries — earlier regex matched "prefixed",
  # "frameworks", "undone" as definite-verb hits.
  _definites=$(printf '%s' "$_tx" | LC_ALL=C grep -oiE '\b(fixed|verified|works|completed|done|tested|confirmed)\b' 2>/dev/null | LC_ALL=C wc -l | tr -d ' \n')
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
  # _test_with_pass was hoisted to the phase-detection block above so the
  # F1-F7 fallback can use it. Reuse the same value here.

  if [ "${_test_with_fail:-0}" -ge 1 ]; then
    _outcome="test_failed"
    _last_test_failed=true
  elif [ "${_test_with_pass:-0}" -ge 1 ]; then
    _outcome="test_passed"
  fi

  # ---------- tone ----------
  # AI-eng C2: tighter regex. Bare 'no' was matching "no problem",
  # "no worries", "non-stop" → false-positive frustration on cordial
  # sessions. Require CONTEXTUAL phrases (no comma, no that, "that is
  # wrong", "not working", "why isn't"/"why won't") to register as a
  # frustration marker.
  local _frustration _tone="neutral"
  _frustration=$(printf '%s' "$_tx" | LC_ALL=C grep -oiE '^USER:.*(\bno,|\bno that|\bno the|\bthat.?s wrong|\bnot working|\bnot getting|\bstop doing|\bwhy (are|isn.?t|won.?t)|\bdoesn.?t work)' 2>/dev/null | LC_ALL=C wc -l | tr -d ' \n')
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

  # ---------- v0.5.1 F1-F7 phase classifier fallback ----------
  # Only fires when the pattern-match block returned "unknown". The 7-rule
  # decision tree uses already-computed counts plus a cached git-dirty
  # probe (per-cycle, 1s timeout via timeout/gtimeout for macOS portability).
  # Target: drop the unknown rate from 74% (pattern-only) to <20%.
  if [ "$_phase" = "unknown" ]; then
    local _git_dirty=0
    local _git_out=""
    if [ -n "${PP_GIT_STATUS_FIXTURE+x}" ]; then
      # Test override: any non-empty fixture means "dirty"; empty means clean.
      _git_out="$PP_GIT_STATUS_FIXTURE"
      [ -n "$_git_out" ] && _git_dirty=1
    else
      _git_out=$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null \
        && { timeout 1 git status --porcelain 2>/dev/null \
             || gtimeout 1 git status --porcelain 2>/dev/null \
             || true; })
      [ -n "$_git_out" ] && _git_dirty=1
    fi
    local _git_staged=0
    if [ "$_git_dirty" = "1" ]; then
      _git_staged=$(printf '%s' "$_git_out" | LC_ALL=C grep -c '^[AMD] ' 2>/dev/null || printf '0')
      case "$_git_staged" in ''|*[!0-9]*) _git_staged=0 ;; esac
    fi

    local _total_tools
    _total_tools=$(( ${_read_count:-0} + ${_edit_count:-0} + ${_bash_count:-0} ))
    local _tx_len="${#_tx}"

    # F1: empty inputs → honest unknown (do NOT mislabel)
    if [ "$_tx_len" -lt 40 ] && [ "$_total_tools" -eq 0 ]; then
      _phase_source="unknown"
    # F2: test_passed + edit → drafting (green test → iterating)
    elif [ "${_test_with_pass:-0}" -ge 1 ] && [ "${_edit_count:-0}" -ge 1 ]; then
      _phase="drafting"; _phase_source="fallback"
    # F3: edit + dirty tree → drafting (uncommitted change in flight)
    elif [ "${_edit_count:-0}" -ge 1 ] && [ "$_git_dirty" = "1" ]; then
      _phase="drafting"; _phase_source="fallback"
    # F4: read-heavy + no edits + dirty → debugging (investigating a wip)
    elif [ "${_read_count:-0}" -ge 3 ] && [ "${_edit_count:-0}" -eq 0 ] && [ "$_git_dirty" = "1" ]; then
      _phase="debugging"; _phase_source="fallback"
    # F5: read-heavy + no edits + clean → planning (surveying before change)
    elif [ "${_read_count:-0}" -ge 2 ] && [ "${_edit_count:-0}" -eq 0 ] && [ "$_git_dirty" = "0" ]; then
      _phase="planning"; _phase_source="fallback"
    # F6: bash-heavy + no tests → planning (running commands, exploring)
    elif [ "${_bash_count:-0}" -ge 3 ] && [ "${_test_with_pass:-0}" -eq 0 ] && [ "${_test_with_fail:-0}" -eq 0 ]; then
      _phase="planning"; _phase_source="fallback"
    # F7: staged changes → drafting (prepared a commit)
    elif [ "$_git_staged" -ge 1 ]; then
      _phase="drafting"; _phase_source="fallback"
    fi
  fi

  # ---------- compose JSON ----------
  jq -n \
    --arg phase "$_phase" \
    --arg phase_source "$_phase_source" \
    --arg confidence "$_confidence" \
    --arg outcome "$_outcome" \
    --arg tone "$_tone" \
    --argjson session_age "$_session_age" \
    --argjson budget "$_budget" \
    --argjson density "${_density:-0}" \
    --argjson last_test_failed "$_last_test_failed" \
    '{
      phase: $phase,
      phase_source: $phase_source,
      confidence: $confidence,
      outcome: $outcome,
      tone: $tone,
      session_age_min: $session_age,
      budget_remaining_pct: $budget,
      last_test_failed: $last_test_failed,
      recent_edit_density: $density
    }'
}
