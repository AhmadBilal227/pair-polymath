#!/usr/bin/env bats
# Pair Polymath — Privacy log (P3.3).
#
# pp_write_privacy_log writes a single overwriting JSON file at
# $PP_CACHE_DIR/last-cycle-payload.json showing what the cycle WOULD send
# to OpenAI. These tests pin its schema, byte-cap behavior, overwrite
# semantics, defensive empty-input path, and the polymath-status surfacing.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export PP_CACHE_DIR="$PP_TEST_HOME/cache"
  mkdir -p "$PP_CACHE_DIR"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/metrics.sh"
  PP_PRIVACY_LOG="$PP_CACHE_DIR/last-cycle-payload.json"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "pp_write_privacy_log: writes a file at cache_dir/last-cycle-payload.json" {
  pp_write_privacy_log "sess1" "transcript bytes here" "grounded facts blob" \
    "src/foo.ts" 7 "gpt-5-mini" "gpt-5"
  [ -f "$PP_PRIVACY_LOG" ]
  [ -s "$PP_PRIVACY_LOG" ]
}

@test "pp_write_privacy_log: output is valid JSON" {
  pp_write_privacy_log "sess1" "tail" "grounded" "f.ts" 7 "gpt-5-mini" "gpt-5"
  run jq -e . < "$PP_PRIVACY_LOG"
  [ "$status" -eq 0 ]
}

@test "pp_write_privacy_log: contains every top-level key the schema promises" {
  pp_write_privacy_log "sess1" "tail" "grounded" "f.ts" 7 "gpt-5-mini" "gpt-5"
  for k in ts session cycle_summary payload_sizes_bytes payload_previews note; do
    run jq -e --arg k "$k" 'has($k)' < "$PP_PRIVACY_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

@test "pp_write_privacy_log: cycle_summary carries the planner pick + both models" {
  pp_write_privacy_log "sess1" "tail" "grounded" "src/picked.ts" 5 \
    "gpt-5-mini" "gpt-5"
  run jq -r '.cycle_summary.planner_picked_file' < "$PP_PRIVACY_LOG"
  [ "$output" = "src/picked.ts" ]
  run jq -r '.cycle_summary.analyst_model' < "$PP_PRIVACY_LOG"
  [ "$output" = "gpt-5-mini" ]
  run jq -r '.cycle_summary.critique_model' < "$PP_PRIVACY_LOG"
  [ "$output" = "gpt-5" ]
  run jq -r '.cycle_summary.lens_count' < "$PP_PRIVACY_LOG"
  [ "$output" = "5" ]
}

@test "pp_write_privacy_log: payload_sizes_bytes reflect actual byte counts" {
  # 50-char transcript, 100-char grounded
  local t="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # 50
  local g
  g=$(printf 'b%.0s' $(seq 1 100))                                 # 100
  pp_write_privacy_log "s" "$t" "$g" "f.ts" 7 "gpt-5-mini" "gpt-5"
  run jq -r '.payload_sizes_bytes.transcript_tail' < "$PP_PRIVACY_LOG"
  [ "$output" = "50" ]
  run jq -r '.payload_sizes_bytes.grounded_facts' < "$PP_PRIVACY_LOG"
  [ "$output" = "100" ]
}

@test "pp_write_privacy_log: previews capped at 500 chars even when input is 2000" {
  # 2000-char string. ${var:0:500} must trim it down inside the helper.
  local big
  big=$(printf 'x%.0s' $(seq 1 2000))
  pp_write_privacy_log "s" "$big" "$big" "f.ts" 7 "gpt-5-mini" "gpt-5"
  run jq -r '.payload_previews.transcript_first_500_chars | length' < "$PP_PRIVACY_LOG"
  [ "$output" = "500" ]
  run jq -r '.payload_previews.grounded_first_500_chars | length' < "$PP_PRIVACY_LOG"
  [ "$output" = "500" ]
  # The size field still records the FULL byte count, not the truncated one.
  run jq -r '.payload_sizes_bytes.transcript_tail' < "$PP_PRIVACY_LOG"
  [ "$output" = "2000" ]
}

@test "pp_write_privacy_log: ts is ISO-8601 UTC" {
  pp_write_privacy_log "s" "t" "g" "f.ts" 1 "gpt-5-mini" "gpt-5"
  run jq -r '.ts' < "$PP_PRIVACY_LOG"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "pp_write_privacy_log: session field round-trips the literal value passed" {
  pp_write_privacy_log "abc-def-ghi" "t" "g" "f.ts" 1 "gpt-5-mini" "gpt-5"
  run jq -r '.session' < "$PP_PRIVACY_LOG"
  [ "$output" = "abc-def-ghi" ]
}

@test "pp_write_privacy_log: second call OVERWRITES (not appends) — file stays one JSON object" {
  pp_write_privacy_log "s1" "first" "first-g" "a.ts" 1 "gpt-5-mini" "gpt-5"
  # Confirm it's the first write
  run jq -r '.session' < "$PP_PRIVACY_LOG"
  [ "$output" = "s1" ]
  # Second cycle with different session id
  pp_write_privacy_log "s2" "second" "second-g" "b.ts" 7 "gpt-5-mini" "gpt-5"
  # File must still parse as a SINGLE JSON object (not concatenated)
  run jq -e . < "$PP_PRIVACY_LOG"
  [ "$status" -eq 0 ]
  # Only s2 should be present — s1 is gone
  run jq -r '.session' < "$PP_PRIVACY_LOG"
  [ "$output" = "s2" ]
  run jq -r '.cycle_summary.planner_picked_file' < "$PP_PRIVACY_LOG"
  [ "$output" = "b.ts" ]
}

@test "pp_write_privacy_log: defensive empty grounded path still writes valid JSON" {
  # Empty transcript + empty grounded must NOT skip the write — we still
  # want the verifier-file to exist so the user knows a cycle ran.
  pp_write_privacy_log "s1" "" "" "<none>" 0 "" ""
  [ -f "$PP_PRIVACY_LOG" ]
  run jq -e . < "$PP_PRIVACY_LOG"
  [ "$status" -eq 0 ]
  run jq -r '.payload_sizes_bytes.transcript_tail' < "$PP_PRIVACY_LOG"
  [ "$output" = "0" ]
  run jq -r '.payload_sizes_bytes.grounded_facts' < "$PP_PRIVACY_LOG"
  [ "$output" = "0" ]
  run jq -r '.payload_previews.transcript_first_500_chars' < "$PP_PRIVACY_LOG"
  [ "$output" = "" ]
}

@test "pp_write_privacy_log: non-numeric lens_count is coerced to 0 (defensive)" {
  pp_write_privacy_log "s1" "t" "g" "f.ts" "notanumber" "gpt-5-mini" "gpt-5"
  [ -f "$PP_PRIVACY_LOG" ]
  run jq -r '.cycle_summary.lens_count' < "$PP_PRIVACY_LOG"
  [ "$output" = "0" ]
}

@test "polymath status: surfaces privacy log path + age when file exists" {
  # Create the file directly so we don't depend on a full cycle running.
  pp_write_privacy_log "s1" "tail" "grounded" "f.ts" 7 "gpt-5-mini" "gpt-5"
  run env PP_CACHE_DIR="$PP_CACHE_DIR" CLAUDE_DIR="$PP_TEST_HOME/.claude" \
    bash "$PP_ROOT/bin/polymath" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Privacy log:"* ]]
  [[ "$output" == *"last-cycle-payload.json"* ]]
}

@test "polymath status: does NOT crash if privacy log absent" {
  # No pp_write_privacy_log call — file should not exist.
  [ ! -f "$PP_PRIVACY_LOG" ]
  run env PP_CACHE_DIR="$PP_CACHE_DIR" CLAUDE_DIR="$PP_TEST_HOME/.claude" \
    bash "$PP_ROOT/bin/polymath" status
  [ "$status" -eq 0 ]
  # And it should NOT print a "Privacy log:" line if the file isn't there
  [[ "$output" != *"Privacy log:"* ]]
}
