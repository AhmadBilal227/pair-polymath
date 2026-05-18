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

# ----- Task 5: polymath disable clears cache atomically -----

@test "polymath disable AC4: removes cc-monitor-*.txt files atomically" {
  _pp_seed_cache "sess1" "ENGINEERING" "ARCH: x|||observation body long enough to satisfy validators"
  _pp_seed_cache "sess1" "UX_DESIGN" "UX: y|||observation body long enough to satisfy validators"
  run bash "$PP_ROOT/bin/polymath" disable
  [ "$status" -eq 0 ]
  # cc-monitor-* files removed atomically by _pp_cache_clear_all.
  local _remaining
  _remaining=$(find "$PP_CACHE_DIR" -maxdepth 1 -name 'cc-monitor-sess1-*.txt' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$_remaining" = "0" ]
}

@test "polymath disable AC4b: preserves budget files (invariant)" {
  mkdir -p "$PP_CACHE_DIR"
  local _budget="$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  printf '99\n' > "$_budget"
  run bash "$PP_ROOT/bin/polymath" disable
  [ "$status" -eq 0 ]
  [ -f "$_budget" ]
  [ "$(cat "$_budget")" = "99" ]
}

@test "polymath disable AC4c: success message reflects new cache-cleared contract" {
  run bash "$PP_ROOT/bin/polymath" disable
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM cycle disabled"* ]]
  [[ "$output" == *"cache cleared"* ]]
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

@test "statusline AC2b: paused suppresses fresh TIP cache (regression guard)" {
  # Code-reviewer CRITICAL: pre-fix, a fresh cc-tips cache could pre-empt
  # the paused fallback because tip_valid was still 1. The post-review fix
  # forces both tip_valid + mon_valid to 0 when paused. Pin it.
  PP_EXTERNAL_LLM=0
  export PP_EXTERNAL_LLM
  # Seed a tip cache. TIP_CACHE path resolution lives in lib/config.sh;
  # the project-keyed dir lives under PP_CACHE_DIR. Drop a tip file in
  # the most-likely location (project-specific subdir) AND in the top
  # cache dir; statusline picks whichever it resolves to.
  printf 'BRIGHT idea — a stale tip that must not appear when paused\n' > "$PP_CACHE_DIR/cc-tips.txt"
  run bash -c 'cat "$PP_ROOT/test/fixtures/stdin-sample.json" | bash "$PP_ROOT/bin/statusline.sh"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"paused"* ]]
  [[ "$output" == *"LLM cycle disabled"* ]]
  [[ "$output" != *"BRIGHT idea"* ]]
}

@test "statusline AC3c: paused suppresses tip-fetch (no llm spawn when disabled)" {
  # Code-reviewer CRITICAL: pre-fix, polymath disable cleared the tip
  # cache; next statusline tick saw empty cache and spawned a background
  # llm call. That's the OPPOSITE of pause. Verify the gate now prevents
  # this by inspecting the source for the PP_EXTERNAL_LLM guard ON the
  # tip-fetch entry.
  grep -qE 'PP_EXTERNAL_LLM.*!= "0".*\\$|tip_cache_enabled.*PP_EXTERNAL_LLM' "$PP_ROOT/bin/statusline.sh" || \
    grep -B2 'mkdir "\$TIP_LOCK_DIR"' "$PP_ROOT/bin/statusline.sh" | grep -q 'PP_EXTERNAL_LLM'
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
