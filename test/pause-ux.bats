#!/usr/bin/env bats
# v0.5.4 pause-ux: visible pause state across all three read paths.
# Spec: docs/v0.5.4-pause-ux-spec.md

setup() {
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$PP_TEST_HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  export PP_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
  mkdir -p "$PP_CACHE_DIR"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

# Helper: write a fake cached observation for SESSION + LENS.
_pp_seed_cache() {
  local _sid="$1" _lens="$2" _body="${3:-hook|||body}"
  printf '%s\n' "$_body" > "$PP_CACHE_DIR/cc-monitor-${_sid}-${_lens}.txt"
}

# ----- Task 2: inject-monitor-insight.sh early-exit when paused -----

@test "inject-hook AC3: source contains PP_EXTERNAL_LLM early-exit gate" {
  # Asserts the gate is in the source. Without this, an integration test
  # can pass by accident in hermetic envs where the hook bails early for
  # other reasons (missing lens config).
  grep -qF 'PP_EXTERNAL_LLM:-1' "$PP_ROOT/hooks/inject-monitor-insight.sh"
  grep -qE 'PP_EXTERNAL_LLM.*=.*"0"' "$PP_ROOT/hooks/inject-monitor-insight.sh"
}

@test "inject-hook AC3 runtime: emits zero bytes when PP_EXTERNAL_LLM=0 even with cached obs" {
  _pp_seed_cache "sess1" "ENGINEERING" "ARCH: test|||This is a fake observation body long enough to satisfy validators"
  PP_EXTERNAL_LLM=0
  export PP_EXTERNAL_LLM
  run bash -c 'echo "{\"session_id\":\"sess1\"}" | bash "$PP_ROOT/hooks/inject-monitor-insight.sh"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----- Task 3: statusline cache-read short-circuit when paused -----

@test "statusline AC2: paused short-circuits cache read (no cached observation rendered)" {
  PP_EXTERNAL_LLM=0
  export PP_EXTERNAL_LLM
  local _sid
  _sid=$(jq -r '.session_id // "unknown"' < "$PP_ROOT/test/fixtures/stdin-sample.json")
  _pp_seed_cache "$_sid" "ENGINEERING" "ARCH: leaked|||This is a fake observation body long enough to satisfy validators"
  run bash -c 'cat "$PP_ROOT/test/fixtures/stdin-sample.json" | bash "$PP_ROOT/bin/statusline.sh"'
  [ "$status" -eq 0 ]
  [[ "$output" != *"leaked"* ]]
  [[ "$output" != *"fake observation body"* ]]
}

# ----- Task 4: statusline paused fallback branch -----

@test "statusline AC1: paused fallback shows visible glyph + recovery hint" {
  PP_EXTERNAL_LLM=0
  export PP_EXTERNAL_LLM
  run bash -c 'cat "$PP_ROOT/test/fixtures/stdin-sample.json" | bash "$PP_ROOT/bin/statusline.sh"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"paused"* ]]
  [[ "$output" == *"LLM cycle disabled"* ]]
  [[ "$output" == *"polymath enable to resume"* ]]
}

@test "inject-hook AC3b: gate is unset/1 leaves the hook proceeding past the gate" {
  # With PP_EXTERNAL_LLM unset or =1, the hook should NOT early-exit at the
  # gate. We verify by patching the script to fail-loud right after the gate
  # — if the gate exits early, the marker won't appear. We don't assert
  # advisory output format (that needs full lens config); we only verify
  # the gate logic flows through correctly when unpaused.
  local _stub="$PP_TEST_HOME/inject-stub.sh"
  awk '
    /^if \[ "\${PP_EXTERNAL_LLM:-1}" = "0" \]; then$/ { in_gate=1; print; next }
    in_gate && /^fi$/ { print; print "echo PAST_GATE_MARKER >&2"; in_gate=0; exit }
    in_gate { print; next }
    { print }
  ' "$PP_ROOT/hooks/inject-monitor-insight.sh" > "$_stub"
  unset PP_EXTERNAL_LLM
  run bash -c "echo '{\"session_id\":\"sess1\"}' | bash \"$_stub\" 2>&1 || true"
  [[ "$output" == *"PAST_GATE_MARKER"* ]]
}
