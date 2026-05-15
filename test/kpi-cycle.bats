#!/usr/bin/env bats
# v0.5.1 KPI cycle emitter (pp_kpi_emit_cycle).
#
# Per-cycle KPI rows appended to kpi-cycle.jsonl. Auto-enabled whenever
# the retry router (enable OR shadow) is on, since the SLO targets in
# the v0.5.1 plan need this data to be measurable. PP_KPI_FORCE_DISABLE
# is the kill switch.

setup() {
  HOME="$(mktemp -d)"; export HOME
  PP_CACHE_DIR="$HOME/.claude/cache"; mkdir -p "$PP_CACHE_DIR"; export PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; export PP_ROOT
}
teardown() { rm -rf "$HOME"; }

@test "kpi_emit: writes one JSONL line with required fields" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_KPI_ENABLE=1
  pp_kpi_emit_cycle '{"session":"s1","cost_usd":0.012,"retry_count":2,"retry_usd":0.008,"inv_count":0,"picked_count":3,"phase":"drafting","phase_source":"pattern"}'
  [ -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ]
  [ "$(wc -l < "$PP_CACHE_DIR/kpi-cycle.jsonl" | tr -d ' ')" = "1" ]
  jq -e '.cost_usd and .retry_count and .phase_source' "$PP_CACHE_DIR/kpi-cycle.jsonl" >/dev/null
}

@test "kpi_emit: no-op when PP_KPI_ENABLE=0 AND no router activity" {
  . "$PP_ROOT/lib/metrics.sh"
  unset PP_KPI_ENABLE PP_RETRY_ROUTER_ENABLE PP_RETRY_ROUTER_SHADOW
  pp_kpi_emit_cycle '{"x":1}'
  [ ! -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ]
}

@test "kpi_emit: AUTO-enabled when router shadow on" {
  . "$PP_ROOT/lib/metrics.sh"
  unset PP_KPI_ENABLE
  export PP_RETRY_ROUTER_SHADOW=1
  pp_kpi_emit_cycle '{"x":1}'
  [ -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ]
}

@test "kpi_emit: PP_KPI_FORCE_DISABLE=1 suppresses even with router on" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_RETRY_ROUTER_SHADOW=1 PP_KPI_FORCE_DISABLE=1
  pp_kpi_emit_cycle '{"x":1}'
  [ ! -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ]
}

# ========================================================
# Task 16: polymath kpi CLI subcommand
# ========================================================

@test "cli: polymath kpi prints rolling-7d summary" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_KPI_ENABLE=1
  # Seed a few entries with today's timestamp so the window includes them.
  local _ts
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local _i
  for _i in 1 2 3; do
    pp_kpi_emit_cycle "{\"ts\":\"$_ts\",\"session\":\"s$_i\",\"cost_usd\":0.01,\"retry_count\":2,\"retry_usd\":0.005,\"phase\":\"drafting\",\"phase_source\":\"pattern\"}"
  done
  run bash "$PP_ROOT/bin/polymath" kpi
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qE 'Cycles:|Total spend:'
}

@test "cli: polymath kpi --json produces parseable JSON" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_KPI_ENABLE=1
  local _ts
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  pp_kpi_emit_cycle "{\"ts\":\"$_ts\",\"session\":\"s1\",\"cost_usd\":0.01,\"retry_count\":1,\"retry_usd\":0.004,\"phase\":\"drafting\",\"phase_source\":\"pattern\"}"
  run bash "$PP_ROOT/bin/polymath" kpi --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.cycles' >/dev/null
}

@test "cli: polymath kpi empty-state hints PP_KPI_ENABLE" {
  # No kpi-cycle.jsonl present yet.
  run bash "$PP_ROOT/bin/polymath" kpi
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'PP_KPI_ENABLE=1'
}
