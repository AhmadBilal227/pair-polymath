#!/usr/bin/env bats
# Pair Polymath — USD telemetry (lib/metrics.sh). P3.1.
#
# Tests cover:
#   - metrics_init creates per-cycle tmp file
#   - metrics_increment_call appends correct TSV rows
#   - _metrics_usd_for_call returns sane USD values across call types + models
#   - metrics_flush_cycle produces ONE valid JSONL entry with expected schema
#   - parallel increments converge to a single rollup with correct totals

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export PP_CACHE_DIR="$PP_TEST_HOME/cache"
  mkdir -p "$PP_CACHE_DIR"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/metrics.sh"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "metrics_init: creates a per-session tmp file" {
  metrics_init "test-session"
  [ -n "$PP_METRICS_TMP" ]
  [ -f "$PP_METRICS_TMP" ]
  [ ! -s "$PP_METRICS_TMP" ]  # empty
}

@test "metrics_init: handles empty session id (falls back to default)" {
  metrics_init ""
  [ -n "$PP_METRICS_TMP" ]
  [[ "$PP_METRICS_TMP" == *"default"* ]]
}

@test "metrics_increment_call: appends one TSV row per call" {
  metrics_init "s1"
  metrics_increment_call planner gpt-5-mini
  metrics_increment_call analyst gpt-5-mini
  metrics_increment_call analyst gpt-5
  local lines
  lines=$(wc -l < "$PP_METRICS_TMP" | tr -d ' ')
  [ "$lines" -eq 3 ]
  # Row 1: planner\tgpt-5-mini
  run head -1 "$PP_METRICS_TMP"
  [[ "$output" == *"planner"* ]]
  [[ "$output" == *"gpt-5-mini"* ]]
}

@test "metrics_increment_call: no-op when metrics_init not called" {
  unset PP_METRICS_TMP
  run metrics_increment_call planner gpt-5-mini
  [ "$status" -eq 0 ]
}

@test "_metrics_usd_for_call: planner gpt-5-mini returns sane USD (>0, <0.01)" {
  metrics_init "s1"
  local usd
  usd=$(_metrics_usd_for_call planner gpt-5-mini)
  # Expected: (800/1M * 0.25) + (50/1M * 2.00) = 0.0002 + 0.0001 = 0.0003
  awk -v u="$usd" 'BEGIN { exit !(u > 0 && u < 0.01) }'
}

@test "_metrics_usd_for_call: analyst gpt-5-mini returns sane USD" {
  metrics_init "s1"
  local usd
  usd=$(_metrics_usd_for_call analyst gpt-5-mini)
  # Expected: (2200/1M * 0.25) + (180/1M * 2.00) = 0.00055 + 0.00036 = 0.00091
  awk -v u="$usd" 'BEGIN { exit !(u > 0 && u < 0.01) }'
}

@test "_metrics_usd_for_call: critique gpt-5 > analyst gpt-5-mini (price + tokens)" {
  metrics_init "s1"
  local cu au
  cu=$(_metrics_usd_for_call critique gpt-5)
  au=$(_metrics_usd_for_call analyst gpt-5-mini)
  # critique on gpt-5: (3500/1M * 1.25) + (500/1M * 10.0) = 0.004375 + 0.005 = 0.009375
  # analyst on gpt-5-mini: 0.00091
  awk -v c="$cu" -v a="$au" 'BEGIN { exit !(c > a) }'
}

@test "_metrics_usd_for_call: gpt-5.5 priced higher than gpt-5 for same call type" {
  metrics_init "s1"
  local five fivefive
  five=$(_metrics_usd_for_call critique gpt-5)
  fivefive=$(_metrics_usd_for_call critique gpt-5.5)
  awk -v a="$five" -v b="$fivefive" 'BEGIN { exit !(b > a) }'
}

@test "_metrics_usd_for_call: unknown call type returns 0" {
  metrics_init "s1"
  local usd
  usd=$(_metrics_usd_for_call WAT gpt-5-mini)
  awk -v u="$usd" 'BEGIN { exit !(u == 0) }'
}

@test "_metrics_usd_for_call: unknown model returns 0 USD" {
  metrics_init "s1"
  local usd
  usd=$(_metrics_usd_for_call analyst claude-4)
  awk -v u="$usd" 'BEGIN { exit !(u == 0) }'
}

@test "metrics_flush_cycle: produces one valid JSONL entry" {
  metrics_init "s1"
  metrics_increment_call planner gpt-5-mini
  metrics_increment_call analyst gpt-5-mini
  metrics_increment_call analyst gpt-5
  metrics_increment_call critique gpt-5
  metrics_flush_cycle "s1"
  [ -f "$PP_METRICS_FILE" ]
  local lines
  lines=$(wc -l < "$PP_METRICS_FILE" | tr -d ' ')
  [ "$lines" -eq 1 ]
  # The line must be valid JSON
  jq -e '.' < "$PP_METRICS_FILE" >/dev/null
}

@test "metrics_flush_cycle: JSONL has ts, session, calls, usd_est, by_type" {
  metrics_init "s1"
  metrics_increment_call planner gpt-5-mini
  metrics_increment_call analyst gpt-5-mini
  metrics_flush_cycle "s1"
  run jq -r '.ts' < "$PP_METRICS_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
  run jq -r '.session' < "$PP_METRICS_FILE"
  [ "$output" = "s1" ]
  run jq -r '.calls' < "$PP_METRICS_FILE"
  [ "$output" = "2" ]
  run jq -r '.usd_est | type' < "$PP_METRICS_FILE"
  [ "$output" = "number" ]
  run jq -r '.by_type | type' < "$PP_METRICS_FILE"
  [ "$output" = "object" ]
  run jq -r '.by_type.planner' < "$PP_METRICS_FILE"
  [ "$output" = "1" ]
  run jq -r '.by_type.analyst' < "$PP_METRICS_FILE"
  [ "$output" = "1" ]
}

@test "metrics_flush_cycle: empty tmp file → no JSONL entry (no-op)" {
  metrics_init "s1"
  # No increments
  metrics_flush_cycle "s1"
  [ ! -f "$PP_METRICS_FILE" ]
}

@test "metrics_flush_cycle: cleans up tmp file" {
  metrics_init "s1"
  metrics_increment_call planner gpt-5-mini
  local tmp="$PP_METRICS_TMP"
  metrics_flush_cycle "s1"
  [ ! -f "$tmp" ]
}

@test "atomicity: 20 sequential increments + one flush → 20 calls in JSONL, USD = 20 × analyst-cost" {
  metrics_init "s1"
  for i in $(seq 1 20); do
    metrics_increment_call analyst gpt-5-mini
  done
  metrics_flush_cycle "s1"
  run jq -r '.calls' < "$PP_METRICS_FILE"
  [ "$output" = "20" ]
  # 20 × (2200/1M * 0.25 + 180/1M * 2.00) = 20 × 0.00091 = 0.0182
  run jq -r '.usd_est' < "$PP_METRICS_FILE"
  # Allow small float drift; assert > 0.018 and < 0.019
  awk -v u="$output" 'BEGIN { exit !(u > 0.018 && u < 0.019) }'
}

@test "atomicity: parallel increments converge to correct total" {
  metrics_init "s1"
  # Bash 3.2 portable parallel fork. 10 background workers append concurrently.
  for i in $(seq 1 10); do
    ( metrics_increment_call analyst gpt-5-mini ) &
  done
  wait
  local lines
  lines=$(wc -l < "$PP_METRICS_TMP" | tr -d ' ')
  [ "$lines" -eq 10 ]
  metrics_flush_cycle "s1"
  run jq -r '.calls' < "$PP_METRICS_FILE"
  [ "$output" = "10" ]
}
