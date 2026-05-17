#!/usr/bin/env bats
# Config/path resolution: CLAUDE_DIR is the default root, PP_* dirs override it.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "config: CLAUDE_DIR drives default state, cache, and user.env paths" {
  export CLAUDE_DIR="$HOME/custom-claude"
  unset PP_STATE_DIR PP_CACHE_DIR PP_USER_CONFIG

  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/config.sh"

  [ "$PP_STATE_DIR" = "$CLAUDE_DIR/pair-polymath" ]
  [ "$PP_CACHE_DIR" = "$CLAUDE_DIR/cache" ]
  [ "$PP_USER_CONFIG" = "$CLAUDE_DIR/pair-polymath/config/user.env" ]
  [ -d "$PP_STATE_DIR" ]
  [ -d "$PP_CACHE_DIR" ]
}

@test "config: loads user.env from custom CLAUDE_DIR" {
  export CLAUDE_DIR="$HOME/custom-claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  printf 'PP_EXTERNAL_LLM=0\n' > "$CLAUDE_DIR/pair-polymath/config/user.env"
  unset PP_STATE_DIR PP_CACHE_DIR PP_USER_CONFIG PP_EXTERNAL_LLM

  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/config.sh"

  [ "$PP_EXTERNAL_LLM" = "0" ]
}

@test "hook cache-test-result: custom CLAUDE_DIR cache is writer and reader root" {
  export CLAUDE_DIR="$HOME/custom-claude"
  unset PP_CACHE_DIR PP_STATE_DIR PP_USER_CONFIG
  local _payload
  _payload=$(jq -nc '{
    session_id:"cfg-hook",
    tool_name:"Bash",
    tool_input:{command:"npm test"},
    tool_response:{is_error:true, content:"failing test output"}
  }')

  run bash -c "printf '%s' '$_payload' | bash '$PP_ROOT/hooks/cache-test-result.sh'"
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_DIR/cache/cc-test-cfg-hook.cache" ]
  [ ! -f "$HOME/.claude/cache/cc-test-cfg-hook.cache" ]
}

@test "hook inject-monitor-insight: custom CLAUDE_DIR cache is observation root" {
  export CLAUDE_DIR="$HOME/custom-claude"
  unset PP_CACHE_DIR PP_STATE_DIR PP_USER_CONFIG
  mkdir -p "$CLAUDE_DIR/cache"
  printf 'ENG: This hook title is long enough|||This advisory body is deliberately long enough to pass the hook validation gate.\n' \
    > "$CLAUDE_DIR/cache/cc-monitor-cfg-inject-ENGINEERING.txt"

  run bash -c "printf '{\"session_id\":\"cfg-inject\"}' | bash '$PP_ROOT/hooks/inject-monitor-insight.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKGROUND ADVISORY"* ]]
  [ -f "$CLAUDE_DIR/cache/cc-monitor-injected-hash-cfg-inject-ENGINEERING.txt" ]
  [ ! -f "$HOME/.claude/cache/cc-monitor-injected-hash-cfg-inject-ENGINEERING.txt" ]
}
