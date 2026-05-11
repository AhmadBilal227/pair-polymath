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
  # 2>/dev/null because round-2 H3 fix emits a stderr warning for unknown
  # models — we still want the function to return $0 so the rollup keeps
  # working, and the warning surfaces to the user via terminal stderr.
  usd=$(_metrics_usd_for_call analyst claude-4 2>/dev/null)
  awk -v u="$usd" 'BEGIN { exit !(u == 0) }'
}

@test "R2-H3: unknown model emits one-line stderr warning (first call only)" {
  metrics_init "s1"
  # Capture stderr; suppress stdout (the USD value).
  local err1 err2
  err1=$(_metrics_usd_for_call analyst gpt-4o-mini 2>&1 >/dev/null)
  err2=$(_metrics_usd_for_call analyst gpt-4o-mini 2>&1 >/dev/null)
  [[ "$err1" == *"unknown model"* ]]
  [[ "$err1" == *"gpt-4o-mini"* ]]
  # Second call must NOT re-warn (rate-limited via tracker marker)
  [ -z "$err2" ]
}

@test "R2-H3: known model does NOT emit stderr warning" {
  metrics_init "s1"
  local err
  err=$(_metrics_usd_for_call analyst gpt-5-mini 2>&1 >/dev/null)
  [ -z "$err" ]
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

@test "metrics_flush_cycle: JSONL has ts, session, calls, usd_est, by_type, by_type_usd" {
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
  # Round-2: by_type_usd new field with per-call-type USD totals.
  run jq -r '.by_type_usd | type' < "$PP_METRICS_FILE"
  [ "$output" = "object" ]
  run jq -r '.by_type_usd.planner | type' < "$PP_METRICS_FILE"
  [ "$output" = "number" ]
  # planner cost > 0 and < 0.001 (it's 0.0003 — see usd_for_call test)
  run jq -r '.by_type_usd.planner' < "$PP_METRICS_FILE"
  awk -v u="$output" 'BEGIN { exit !(u > 0 && u < 0.001) }'
}

@test "R2-H1: flush under non-C numeric locale still produces valid JSONL" {
  metrics_init "s1"
  metrics_increment_call planner gpt-5-mini
  metrics_increment_call analyst gpt-5-mini
  # de_DE.UTF-8 typically isn't installed in CI, so use the numeric-only
  # form which awk honors via LC_NUMERIC. Bash inherits LC_NUMERIC to the
  # subprocess. If this env locale doesn't exist, awk silently falls back
  # to C and the test still passes (which is fine — we're verifying the
  # fix doesn't BREAK the C path either).
  LC_NUMERIC=de_DE.UTF-8 metrics_flush_cycle "s1"
  [ -f "$PP_METRICS_FILE" ]
  # The MUST condition: the line parses as JSON. Pre-fix, jq would reject
  # "0,000910" as invalid and the entry would be dropped (empty file).
  run jq -e '.' < "$PP_METRICS_FILE"
  [ "$status" -eq 0 ]
  # usd_est must be a number, not a string
  run jq -r '.usd_est | type' < "$PP_METRICS_FILE"
  [ "$output" = "number" ]
}

@test "R2-H1: by_type_usd values are numeric under non-C locale" {
  metrics_init "s1"
  metrics_increment_call analyst gpt-5-mini
  metrics_increment_call critique gpt-5
  LC_NUMERIC=fr_FR.UTF-8 metrics_flush_cycle "s1"
  run jq -r '.by_type_usd.analyst | type' < "$PP_METRICS_FILE"
  [ "$output" = "number" ]
  run jq -r '.by_type_usd.critique | type' < "$PP_METRICS_FILE"
  [ "$output" = "number" ]
}

@test "R2-M1: metrics_init recovers leftover tmp from crashed prior cycle" {
  # Simulate a prior cycle that put rows into the tmp file and was killed
  # before flushing. metrics_init on the same session id should flush
  # what's there BEFORE starting fresh — otherwise that cycle's cost is
  # silently lost.
  metrics_init "s1"
  metrics_increment_call analyst gpt-5-mini
  # DON'T flush — simulate SIGTERM. We're now leaving 1 row in the tmp.
  local pre_count=0
  [ -f "$PP_METRICS_FILE" ] && pre_count=$(wc -l < "$PP_METRICS_FILE" | tr -d ' ')

  # New cycle on same session id should auto-recover.
  metrics_init "s1"
  metrics_increment_call planner gpt-5-mini
  metrics_flush_cycle "s1"

  # Expect 2 JSONL rows: the recovered (analyst) and the new (planner).
  local post_count
  post_count=$(wc -l < "$PP_METRICS_FILE" | tr -d ' ')
  [ "$post_count" -eq $((pre_count + 2)) ]
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

# === Round-3 review fixes ===

@test "R3-PR10-3: jq failure preserves tmp for next-init recovery" {
  # Shadow jq with a function that always fails. metrics_flush_cycle should
  # NOT delete PP_METRICS_TMP — the next metrics_init must recover it.
  metrics_init "s1"
  metrics_increment_call planner gpt-5-mini
  local tmp_path="$PP_METRICS_TMP"
  [ -s "$tmp_path" ]

  # Force jq to fail by overriding it in this shell. Subshells inherit
  # functions via `export -f` (or sourcing) — but since metrics_flush_cycle
  # is itself a function called in this shell, it sees our jq override.
  jq() { return 1; }
  export -f jq 2>/dev/null || true

  run metrics_flush_cycle "s1"
  [ "$status" -ne 0 ]

  # tmp must survive
  [ -s "$tmp_path" ]
  # metrics.jsonl must NOT contain a corrupt entry
  if [ -f "$PP_METRICS_FILE" ]; then
    local lines
    lines=$(wc -l < "$PP_METRICS_FILE" | tr -d ' ')
    [ "$lines" -eq 0 ]
  fi

  # Recover: clear the jq override and re-init. metrics_init sees the
  # leftover tmp and flushes it before truncating.
  unset -f jq
  metrics_init "s1"
  [ -f "$PP_METRICS_FILE" ]
  local post
  post=$(wc -l < "$PP_METRICS_FILE" | tr -d ' ')
  [ "$post" -eq 1 ]
}

@test "R3-PR10-4: concurrent metrics_flush_cycle produces atomic JSONL" {
  # 10 parallel cycles writing to the same metrics.jsonl. Without the
  # append lock, `cat >> "$PP_METRICS_FILE"` calls can interleave and
  # produce partial / corrupted lines. With the lock, every line must
  # parse as JSON and we must see exactly 10 lines.
  local sub_root="$PP_TEST_HOME/r3-parallel"
  mkdir -p "$sub_root"
  export PP_CACHE_DIR="$sub_root"
  export PP_METRICS_FILE="$PP_CACHE_DIR/metrics.jsonl"
  export PP_METRICS_TMP_PREFIX="$PP_CACHE_DIR/metrics-tmp"
  export PP_METRICS_LOCK="${PP_METRICS_FILE}.lock"
  export PP_METRICS_WARN_LOG="$PP_CACHE_DIR/metrics-warnings.log"
  mkdir -p "$PP_CACHE_DIR"

  for i in 1 2 3 4 5 6 7 8 9 10; do
    (
      . "$PP_ROOT/lib/metrics.sh"
      metrics_init "session-$i"
      metrics_increment_call planner gpt-5-mini
      metrics_increment_call analyst gpt-5-mini
      metrics_flush_cycle "session-$i"
    ) &
  done
  wait

  [ -s "$PP_METRICS_FILE" ]
  local lines
  lines=$(wc -l < "$PP_METRICS_FILE" | tr -d ' ')
  [ "$lines" -eq 10 ]
  # Every line must parse as JSON
  run jq -c . < "$PP_METRICS_FILE"
  [ "$status" -eq 0 ]
}

@test "R3-PR10-6: unknown-model warnings persist to warnings log" {
  metrics_init "s1"
  metrics_increment_call planner gpt-4o-mini
  metrics_flush_cycle "s1"
  [ -s "$PP_METRICS_WARN_LOG" ]
  run cat "$PP_METRICS_WARN_LOG"
  [[ "$output" == *"gpt-4o-mini"* ]]
  [[ "$output" == *"unknown model"* ]]
}

@test "R3-PR10-6: same unknown model warns only once per cache dir" {
  metrics_init "s1"
  metrics_increment_call planner gpt-4o
  metrics_increment_call analyst gpt-4o
  metrics_increment_call critique gpt-4o
  metrics_flush_cycle "s1"
  local count
  count=$(grep -c "gpt-4o" "$PP_METRICS_WARN_LOG")
  [ "$count" -eq 1 ]
}
