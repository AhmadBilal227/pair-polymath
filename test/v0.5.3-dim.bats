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

@test "dim: get_current_state returns 'monitoring' when no state file" {
  result=$(pp_dim_get_current_state "abcd1234")
  [ "$result" = "monitoring" ]
}

@test "dim: append_transition then get_current_state reflects latest" {
  pp_dim_append_transition "abcd1234" "monitoring" "gated" "gate cleared" "auto" '{}'
  result=$(pp_dim_get_current_state "abcd1234")
  [ "$result" = "gated" ]
}

@test "dim: multiple transitions — get_current_state returns latest" {
  pp_dim_append_transition "abcd1234" "monitoring" "gated" "test1" "auto" '{}'
  pp_dim_append_transition "abcd1234" "gated" "active" "test2" "auto" '{}'
  pp_dim_append_transition "abcd1234" "active" "quarantine" "test3" "auto" '{}'
  result=$(pp_dim_get_current_state "abcd1234")
  [ "$result" = "quarantine" ]
}

@test "dim: append_transition writes a single valid JSONL row" {
  pp_dim_append_transition "abcd1234" "monitoring" "gated" "test" "auto" '{"n":42}'
  f=$(pp_dim_state_file_path "abcd1234")
  [ -f "$f" ]
  [ "$(wc -l < "$f")" -eq 1 ]
  jq -e '.from == "monitoring" and .to == "gated" and .reason == "test" and .source == "auto" and .gate_snapshot.n == 42' "$f"
}

@test "dim: two projects have independent state" {
  pp_dim_append_transition "aaaaaaaa" "monitoring" "gated" "p1" "auto" '{}'
  pp_dim_append_transition "bbbbbbbb" "monitoring" "active" "p2" "auto" '{}'
  s1=$(pp_dim_get_current_state "aaaaaaaa")
  s2=$(pp_dim_get_current_state "bbbbbbbb")
  [ "$s1" = "gated" ]
  [ "$s2" = "active" ]
}
