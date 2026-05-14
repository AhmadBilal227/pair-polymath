#!/usr/bin/env bats
# v0.5.1 Tier 0 — Cost-aware retry router.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}
teardown() { rm -rf "$HOME"; }

@test "env: PP_RETRY_ROUTER_ENABLE default is 0" {
  unset PP_RETRY_ROUTER_ENABLE
  # shellcheck source=../config/default.env
  . "$PP_ROOT/config/default.env"
  [ "${PP_RETRY_ROUTER_ENABLE:-NOTSET}" = "0" ]
}

@test "env: PP_RETRY_ROUTER_SHADOW default is 0" {
  unset PP_RETRY_ROUTER_SHADOW
  . "$PP_ROOT/config/default.env"
  [ "${PP_RETRY_ROUTER_SHADOW:-NOTSET}" = "0" ]
}

@test "env: PP_KPI_ENABLE default is 0" {
  unset PP_KPI_ENABLE
  . "$PP_ROOT/config/default.env"
  [ "${PP_KPI_ENABLE:-NOTSET}" = "0" ]
}

@test "env: PP_ESCALATION_STREAK_THRESHOLD default is 3" {
  unset PP_ESCALATION_STREAK_THRESHOLD
  . "$PP_ROOT/config/default.env"
  [ "${PP_ESCALATION_STREAK_THRESHOLD:-NOTSET}" = "3" ]
}
