#!/usr/bin/env bats
# Tests for lib/router-signals.sh — deterministic feature extraction
# from filtered transcript + tool-call JSON array.
#
# v0.4 Phase 2 Task 1. Per the GPT plan-review amendment, the emitted
# signals JSON MUST contain all 8 promised fields:
#   phase, confidence, outcome, tone,
#   session_age_min, budget_remaining_pct, last_test_failed,
#   recent_edit_density

setup() {
  HOME="$(mktemp -d)"
  export HOME
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  # shellcheck source=../lib/router-signals.sh
  . "$PP_ROOT/lib/router-signals.sh"
  # Clean env: defaults must surface in tests where vars are not set.
  unset PP_SESSION_START_EPOCH PP_BUDGET_REMAINING_PCT
}

teardown() { rm -rf "$HOME"; }

# ----- Schema completeness (C1 fix from GPT plan review) -----

@test "signals: emits ALL 8 promised fields with safe defaults on empty input" {
  run pp_router_extract_signals "" "[]"
  [ "$status" -eq 0 ]
  for f in phase confidence outcome tone session_age_min budget_remaining_pct last_test_failed recent_edit_density; do
    if ! echo "$output" | jq -e --arg k "$f" 'has($k)' >/dev/null 2>&1; then
      echo "missing key: $f" >&2
      echo "output: $output" >&2
      return 1
    fi
  done
  # Default values for unknown signals.
  echo "$output" | jq -e '.phase == "unknown"' >/dev/null
  echo "$output" | jq -e '.confidence == "medium"' >/dev/null
  echo "$output" | jq -e '.outcome == "unknown"' >/dev/null
  echo "$output" | jq -e '.tone == "neutral"' >/dev/null
  echo "$output" | jq -e '.session_age_min == 0' >/dev/null
  echo "$output" | jq -e '.budget_remaining_pct == 100' >/dev/null
  echo "$output" | jq -e '.last_test_failed == false' >/dev/null
  echo "$output" | jq -e '.recent_edit_density == 0' >/dev/null
}

# ----- phase detection -----

@test "signals: planning phase detected from 'let me think' / 'consider' patterns" {
  txt='USER: should we refactor?
CLAUDE: let me think about this. Consider the trade-offs.'
  run pp_router_extract_signals "$txt" "[]"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.phase == "planning"' >/dev/null
}

@test "signals: drafting phase when Edit/Write tools dominate" {
  tools='[{"tool":"Edit","target":"/a","summary":null},{"tool":"Write","target":"/b","summary":null},{"tool":"Edit","target":"/c","summary":null},{"tool":"Edit","target":"/d","summary":null}]'
  run pp_router_extract_signals "USER: make it work" "$tools"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.phase == "drafting"' >/dev/null
}

@test "signals: drafting phase recognises MultiEdit (full name, not 6-char truncated; I2 fix)" {
  tools='[{"tool":"MultiEdit","target":"/a","summary":null},{"tool":"MultiEdit","target":"/b","summary":null},{"tool":"MultiEdit","target":"/c","summary":null}]'
  run pp_router_extract_signals "" "$tools"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.phase == "drafting"' >/dev/null
}

@test "signals: debugging phase when Bash test target FAILS (I3: tightened to test invocations only)" {
  tools='[{"tool":"Bash","target":"pnpm test src/auth","summary":"FAIL src/auth.test.ts (3 of 12 passing)"},{"tool":"Read","target":"/x","summary":null}]'
  run pp_router_extract_signals "USER: tests failing" "$tools"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.phase == "debugging"' >/dev/null
}

@test "signals: NOT debugging when non-test Bash had an error (I3: regex tightened)" {
  # A linter error or git failure should NOT flip outcome to test_failed
  # (or phase to debugging). Only test-target invocations count.
  tools='[{"tool":"Bash","target":"git push origin main","summary":"error: failed to push some refs"}]'
  run pp_router_extract_signals "USER: pushing" "$tools"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.phase != "debugging"' >/dev/null
  echo "$output" | jq -e '.outcome != "test_failed"' >/dev/null
}

# ----- confidence detection -----

@test "signals: confidence=low detected from hedge markers in Claude text" {
  txt='CLAUDE: I think maybe this could work. Perhaps we should try this approach but I am not sure.'
  run pp_router_extract_signals "$txt" "[]"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.confidence == "low"' >/dev/null
}

@test "signals: confidence=high detected from definite verbs in Claude text" {
  txt='CLAUDE: This is fixed. The implementation works. I verified all tests pass and confirmed the fix.'
  run pp_router_extract_signals "$txt" "[]"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.confidence == "high"' >/dev/null
}

# ----- outcome detection -----

@test "signals: outcome=test_failed only when target matches test patterns AND summary has FAIL" {
  tools='[{"tool":"Bash","target":"pytest tests/","summary":"FAIL 3 tests"}]'
  run pp_router_extract_signals "" "$tools"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "test_failed"' >/dev/null
  echo "$output" | jq -e '.last_test_failed == true' >/dev/null
}

@test "signals: outcome=test_passed when test target + passing summary" {
  tools='[{"tool":"Bash","target":"go test ./...","summary":"PASS: all 47 tests passing"}]'
  run pp_router_extract_signals "" "$tools"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "test_passed"' >/dev/null
  echo "$output" | jq -e '.last_test_failed == false' >/dev/null
}

# ----- tone detection -----

@test "signals: tone=frustrated from multiple negation markers in user messages" {
  txt='USER: no that is wrong
USER: stop doing this
USER: why are you not getting it'
  run pp_router_extract_signals "$txt" "[]"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tone == "frustrated"' >/dev/null
}

@test "signals: tone=neutral when no frustration markers" {
  txt='USER: please refactor the auth module
CLAUDE: I will split it into two functions'
  run pp_router_extract_signals "$txt" "[]"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tone == "neutral"' >/dev/null
}

# ----- edit density -----

@test "signals: recent_edit_density counts Edit/Write/MultiEdit events" {
  tools='[{"tool":"Edit","target":"/a","summary":null},{"tool":"Edit","target":"/b","summary":null},{"tool":"Read","target":"/c","summary":null},{"tool":"Write","target":"/d","summary":null},{"tool":"MultiEdit","target":"/e","summary":null}]'
  run pp_router_extract_signals "" "$tools"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.recent_edit_density == 4' >/dev/null
}

# ----- env-derived signals (C1 fix: session_age + budget_remaining) -----

@test "signals: session_age_min derived from PP_SESSION_START_EPOCH env var" {
  # Now is ~now; SESSION_START 600 seconds ago → 10 min
  past=$(($(date +%s) - 600))
  PP_SESSION_START_EPOCH="$past" run pp_router_extract_signals "" "[]"
  [ "$status" -eq 0 ]
  age=$(echo "$output" | jq -r '.session_age_min')
  # Allow ±1 min jitter for test execution time
  [ "$age" -ge 9 ] && [ "$age" -le 11 ]
}

@test "signals: budget_remaining_pct read from PP_BUDGET_REMAINING_PCT env" {
  PP_BUDGET_REMAINING_PCT=42 run pp_router_extract_signals "" "[]"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.budget_remaining_pct == 42' >/dev/null
}

# ----- robustness -----

@test "signals: malformed tool_summary JSON does not crash extraction" {
  run pp_router_extract_signals "USER: hi" "not-json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("phase")' >/dev/null
}

@test "signals: emits valid JSON parseable by jq" {
  run pp_router_extract_signals "USER: hello" '[{"tool":"Read","target":"/x","summary":"ok"}]'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "object"' >/dev/null
}
