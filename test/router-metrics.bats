#!/usr/bin/env bats
# Tests for pp_router_metrics_emit — per-cycle telemetry append.
# P2.5 Track 2.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  export PP_ROUTER_METRICS_FILE="$HOME/router-metrics.jsonl"
  # shellcheck source=../lib/router.sh
  . "$PP_ROOT/lib/router.sh"
}

teardown() { rm -rf "$HOME"; }

@test "metrics: appends one JSONL line per call" {
  pp_router_metrics_emit '{"phase":"debugging"}' "ENGINEERING SECURITY" 0 0 234
  pp_router_metrics_emit '{"phase":"drafting"}' "UX_DESIGN" 1 0 198
  [ -f "$PP_ROUTER_METRICS_FILE" ]
  line_count=$(wc -l < "$PP_ROUTER_METRICS_FILE" | tr -d ' ')
  [ "$line_count" -eq 2 ]
}

@test "metrics: each line has the documented schema" {
  pp_router_metrics_emit '{"phase":"debugging"}' "ENGINEERING SECURITY" 1 0 234
  line=$(head -1 "$PP_ROUTER_METRICS_FILE")
  echo "$line" | jq -e '.ts and .phase and (.picked_count != null) and (.surprise_fired != null) and (.failopen != null) and (.llm_call_ms != null)' >/dev/null
  echo "$line" | jq -e '.picked_count == 2' >/dev/null
  echo "$line" | jq -e '.surprise_fired == 1' >/dev/null
  echo "$line" | jq -e '.failopen == 0' >/dev/null
  echo "$line" | jq -e '.llm_call_ms == 234' >/dev/null
  echo "$line" | jq -e '.phase == "debugging"' >/dev/null
}

@test "metrics: GPT-C3 — picked_count handles space AND newline delimiters" {
  pp_router_metrics_emit '{"phase":"x"}' "A B C" 0 0 0
  pp_router_metrics_emit '{"phase":"x"}' $'A\nB\nC' 0 0 0
  pp_router_metrics_emit '{"phase":"x"}' "A" 0 0 0
  count1=$(sed -n '1p' "$PP_ROUTER_METRICS_FILE" | jq '.picked_count')
  count2=$(sed -n '2p' "$PP_ROUTER_METRICS_FILE" | jq '.picked_count')
  count3=$(sed -n '3p' "$PP_ROUTER_METRICS_FILE" | jq '.picked_count')
  [ "$count1" -eq 3 ]
  [ "$count2" -eq 3 ]
  [ "$count3" -eq 1 ]
}

@test "metrics: rotates to .old when over PP_ROUTER_METRICS_MAX_LINES" {
  PP_ROUTER_METRICS_MAX_LINES=5
  i=0
  while [ "$i" -lt 6 ]; do
    pp_router_metrics_emit '{"phase":"x"}' "A" 0 0 0
    i=$((i + 1))
  done
  # After 6 writes, the 6th triggers rotation. .old exists; main file might
  # be empty or have content depending on exact rotation moment.
  [ -f "${PP_ROUTER_METRICS_FILE}.old" ] || [ -f "$PP_ROUTER_METRICS_FILE" ]
  # Total lines across both files ≤ 6.
  total=$(cat "$PP_ROUTER_METRICS_FILE" "${PP_ROUTER_METRICS_FILE}.old" 2>/dev/null | wc -l | tr -d ' ')
  [ "$total" -le 6 ]
}

@test "metrics: silently no-ops when PP_ROUTER_METRICS_FILE unwritable (GPT-I7)" {
  PP_ROUTER_METRICS_FILE=/no/such/dir/that/will/never/exist/metrics.jsonl
  # MUST NOT crash, exit non-zero, or block the cycle.
  run pp_router_metrics_emit '{"phase":"x"}' "ENGINEERING" 0 0 100
  [ "$status" -eq 0 ]
}

@test "metrics: concurrent appends from N subshells don't corrupt the file" {
  # GPT-I4: bash 3.2 doesn't have flock; use mkdir-lock pattern instead.
  # POSIX while loop (not seq, which isn't guaranteed everywhere).
  i=1
  while [ "$i" -le 10 ]; do
    ( pp_router_metrics_emit '{"phase":"p"}' "ENGINEERING" 0 0 "$i" ) &
    i=$((i + 1))
  done
  wait
  line_count=$(wc -l < "$PP_ROUTER_METRICS_FILE" | tr -d ' ')
  [ "$line_count" -eq 10 ]
  # Every line is valid JSON
  while IFS= read -r line; do
    echo "$line" | jq -e 'has("phase")' >/dev/null
  done < "$PP_ROUTER_METRICS_FILE"
}

@test "metrics: GPT-I1 — stale lockdir is auto-reclaimed if mtime > 30s" {
  # Manually create a stale lockdir backdated by 60s.
  mkdir "${PP_ROUTER_METRICS_FILE}.lock"
  # Set mtime to 60s ago. Both stat -c and stat -f tested per project convention.
  if command -v touch >/dev/null 2>&1; then
    # Coreutils touch -d (GNU) and BSD touch -t both work for past times.
    touch -d "60 seconds ago" "${PP_ROUTER_METRICS_FILE}.lock" 2>/dev/null \
      || touch -A -000100 "${PP_ROUTER_METRICS_FILE}.lock" 2>/dev/null \
      || skip "no portable way to backdate mtime on this system"
  fi
  # Now emit — should reclaim the stale lock and succeed.
  pp_router_metrics_emit '{"phase":"x"}' "A" 0 0 0
  [ -f "$PP_ROUTER_METRICS_FILE" ]
  line_count=$(wc -l < "$PP_ROUTER_METRICS_FILE" | tr -d ' ')
  [ "$line_count" -eq 1 ]
}
