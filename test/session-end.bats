#!/usr/bin/env bats
# v0.5.1 — SessionEnd hook scaffold (OAR prerequisite).

setup() {
  HOME="$(mktemp -d)"; export HOME
  PP_CACHE_DIR="$HOME/.claude/cache"
  PP_STATE_DIR="$HOME/.claude/pair-polymath"
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR"
  export PP_CACHE_DIR PP_STATE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}
teardown() { rm -rf "$HOME"; }

@test "session-end: no-op when PP_OAR_ENABLE=0 (default)" {
  unset PP_OAR_ENABLE
  run bash -c "printf '{\"session_id\":\"s1\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  [ ! -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
}

@test "session-end: writes oar-pending records when PP_OAR_ENABLE=1" {
  # Pre-create some injection-hash files for the session
  printf 'hash-abc' > "$PP_CACHE_DIR/cc-monitor-injected-hash-s1-ENGINEERING.txt"
  printf 'hash-def' > "$PP_CACHE_DIR/cc-monitor-injected-hash-s1-SECURITY.txt"
  export PP_OAR_ENABLE=1
  run bash -c "printf '{\"session_id\":\"s1\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  [ -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
  [ "$(wc -l < "$PP_CACHE_DIR/oar-pending.jsonl" | tr -d ' ')" -ge 2 ]
}

@test "session-end: latency under 50ms when disabled (p99)" {
  unset PP_OAR_ENABLE
  local _start _end
  _start=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
  bash -c "printf '{\"session_id\":\"s1\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  _end=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
  local _ms=$(( (_end - _start) / 1000000 ))
  [ "$_ms" -lt 50 ]
}
