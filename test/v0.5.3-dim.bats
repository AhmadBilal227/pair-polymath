#!/usr/bin/env bats

setup() {
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/state"
  PP_HOME="$CLAUDE_DIR/pair-polymath"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR PP_HOME
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR" "$PP_HOME"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
}

teardown() {
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] && rm -rf "$HOME"
}

@test "dim: lib sources with source guard" {
  [ "${_PP_DIM_SOURCED:-0}" = "1" ]
}

@test "dim: pp_dim_state_file_path returns per-project sharded path" {
  result=$(pp_dim_state_file_path "abcd1234")
  [ "$result" = "$PP_CACHE_DIR/dim-state.abcd1234.jsonl" ]
}

@test "dim: pp_dim_last_eval_path returns per-project sharded path" {
  result=$(pp_dim_last_eval_path "abcd1234")
  [ "$result" = "$PP_CACHE_DIR/dim-last-eval-epoch.abcd1234.txt" ]
}
