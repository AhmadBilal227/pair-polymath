#!/usr/bin/env bats
# polymath doctor: end-to-end health checks.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$PP_TEST_HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$CLAUDE_DIR"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/doctor.sh"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "doctor: smoke — runs without crashing" {
  run bash "$PP_ROOT/bin/polymath" doctor
  # Exit may be 0 or 1 depending on host; we only assert no crash
  [ "$status" -lt 128 ]
  [[ "$output" == *"Pair Polymath doctor"* ]]
  [[ "$output" == *"Summary:"* ]]
  [[ "$output" == *"Status:"* ]]
}

@test "doctor: reports missing settings.json as red" {
  # CLAUDE_DIR exists but settings.json doesn't
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"settings.json"* ]]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"BROKEN"* ]]
}

@test "doctor: reports valid settings.json as green" {
  echo '{"statusLine":{"command":"bash /tmp/statusline.sh"},"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"/tmp/inject-monitor-insight.sh"}]}],"PostToolUse":[{"hooks":[{"command":"/tmp/cache-test-result.sh"}]}]}}' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"settings.json"* ]]
  [[ "$output" == *"valid"* ]]
}

@test "doctor: reports invalid settings.json as red" {
  echo 'not-json' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"invalid JSON"* ]]
  [ "$status" -eq 1 ]
}

@test "doctor: reports hooks wired correctly" {
  echo '{"statusLine":{"command":"bash /tmp/statusline.sh"},"hooks":{"UserPromptSubmit":[{"matcher":"*","hooks":[{"type":"command","command":"/path/inject-monitor-insight.sh","timeout":3}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/path/cache-test-result.sh","timeout":3}]}]}}' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"hooks wired"* ]]
  [[ "$output" == *"UserPromptSubmit + PostToolUse"* ]]
}

@test "doctor: reports missing hooks as red" {
  echo '{"statusLine":{"command":"bash /tmp/statusline.sh"},"hooks":{}}' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"hooks wired"* ]]
  [[ "$output" == *"missing"* ]]
}

@test "doctor: lens registry loads (built-in 7)" {
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"lenses"* ]]
  [[ "$output" == *"7 loaded"* ]]
}

@test "doctor: prompts present (built-in 6)" {
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"prompts"* ]]
  [[ "$output" == *"6/6 built-in present"* ]]
}

@test "doctor: smoke fixture runs to exit 0" {
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"statusline smoke"* ]]
  [[ "$output" == *"exit 0"* ]]
}

@test "doctor: SUMMARY line lists counts in order green/yellow/red" {
  run bash "$PP_ROOT/bin/polymath" doctor
  # The summary line should match the pattern
  echo "$output" | grep -q 'Summary: .* green, .* yellow, .* red'
}

@test "doctor --network: skipped when no llm available (placeholder)" {
  # We can't reliably test the network path in CI without a live key,
  # but we can verify the flag is accepted without crashing.
  run bash "$PP_ROOT/bin/polymath" doctor --network
  [ "$status" -lt 128 ]
}
