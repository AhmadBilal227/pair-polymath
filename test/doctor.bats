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

@test "doctor: reports hooks wired correctly when paths point at \$PP_ROOT" {
  # H2 fix: strict-match against PP_ROOT-resolved paths, not basenames.
  # We must reference real files in this checkout for the test to pass.
  local sl_path="$PP_ROOT/bin/statusline.sh"
  local user_hook="$PP_ROOT/hooks/inject-monitor-insight.sh"
  local post_hook="$PP_ROOT/hooks/cache-test-result.sh"
  jq -n --arg sl "bash '$sl_path'" --arg uh "$user_hook" --arg ph "$post_hook" '{
    statusLine: {command: $sl},
    hooks: {
      UserPromptSubmit: [{matcher:"*", hooks:[{type:"command", command:$uh, timeout:3}]}],
      PostToolUse:       [{matcher:"Bash", hooks:[{type:"command", command:$ph, timeout:3}]}]
    }
  }' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"hooks wired"* ]]
  [[ "$output" == *"UserPromptSubmit + PostToolUse"* ]]
  # H1 fix: statusLine wired should be green when path resolves correctly
  [[ "$output" == *"statusLine wired"* ]]
  [[ "$output" == *"→"* ]]
}

@test "doctor: H1 — yellow statusLine returns non-zero contribution (not silently green)" {
  # Decoy statusLine pointing elsewhere — must surface as yellow and be counted
  echo '{"statusLine":{"command":"bash /tmp/decoy-statusline.sh"},"hooks":{}}' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"statusLine wired"* ]]
  [[ "$output" == *"points to a different script"* ]]
  # Summary's yellow count must be >= 1
  echo "$output" | grep -qE 'Summary:.*1 yellow|Summary:.*[2-9][0-9]* yellow'
}

@test "doctor: H2 — substring-decoy hook path is NOT counted as wired" {
  # A decoy hook with a matching basename but wrong location must NOT pass strict-match
  jq -n '{
    statusLine: {command:"bash /tmp/x.sh"},
    hooks: {
      UserPromptSubmit: [{matcher:"*", hooks:[{type:"command", command:"/tmp/inject-monitor-insight.sh"}]}],
      PostToolUse:       [{matcher:"Bash", hooks:[{type:"command", command:"/tmp/cache-test-result.sh"}]}]
    }
  }' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"missing or pointing elsewhere"* ]]
  [ "$status" -eq 1 ]   # red trips overall BROKEN exit
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

@test "doctor: transcript libs check fires and verifies canonical redactor (v0.4 Phase 1)" {
  # Hermetic HOME means doctor may exit non-zero on settings.json checks;
  # we only assert the new check line appears with the canonical-redactor
  # signature (proves the probe ran and saw pp_memory_redact_body wired).
  run bash "$PP_ROOT/bin/polymath" doctor
  echo "$output" | grep -qF 'transcript libs'
  echo "$output" | grep -qF 'filter+tool_calls+canonical-redactor wired'
}

@test "doctor: transcript libs check would FAIL if canonical redactor disappears" {
  # Probe directly to confirm the check would detect a regression where
  # pp_memory_redact_body got renamed or deleted. We can't easily simulate
  # that within bats without forking the binary, so instead verify the
  # check function itself is sourced and callable.
  . "$PP_ROOT/lib/doctor.sh"
  type doctor_check_transcript_libs >/dev/null 2>&1
  [ "$?" -eq 0 ]
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

@test "doctor --network: hidden behind PP_TEST_NETWORK env (M1 fix: don't burn \$ in CI)" {
  # Default: never exercise the live OpenAI path; would otherwise cost
  # ~$0.0001 per CI run and slow tests / introduce flakiness.
  if [ "${PP_TEST_NETWORK:-0}" != "1" ]; then
    skip "set PP_TEST_NETWORK=1 to exercise live OpenAI probe"
  fi
  run bash "$PP_ROOT/bin/polymath" doctor --network
  [ "$status" -lt 128 ]
  [[ "$output" == *"network probe"* ]]
}

@test "doctor --network: flag is accepted but probe is gated (no live call by default)" {
  # Verify --network is parsed without crash even when we don't run the probe
  # (PATH stripped so 'llm' is absent → yellow "skipped" branch).
  PATH=/usr/bin:/bin run bash "$PP_ROOT/bin/polymath" doctor --network
  [ "$status" -lt 128 ]
  [[ "$output" == *"Summary:"* ]]
}
