#!/usr/bin/env bats
setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/lock.sh"
}
teardown() { rm -rf "$SANDBOX"; }

@test "lock: pp_memory_lock acquires and unlock releases" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_lock "$SANDBOX/proj"
  [ -d "$SANDBOX/proj/.maint.lock" ]
  pp_memory_unlock "$SANDBOX/proj"
  [ ! -d "$SANDBOX/proj/.maint.lock" ]
}

@test "lock: pp_memory_with_lock runs func under lock, releases on success" {
  mkdir -p "$SANDBOX/proj"
  _bats_helper_write_output() { echo ran > "$SANDBOX/proj/output"; }
  pp_memory_with_lock "$SANDBOX/proj" _bats_helper_write_output
  [ -f "$SANDBOX/proj/output" ]
  [ ! -d "$SANDBOX/proj/.maint.lock" ]
}

@test "lock: pp_memory_with_lock releases on failure" {
  mkdir -p "$SANDBOX/proj"
  run pp_memory_with_lock "$SANDBOX/proj" false
  [ "$status" -ne 0 ]
  [ ! -d "$SANDBOX/proj/.maint.lock" ]
}

@test "lock: second acquirer waits then fails after timeout" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_lock "$SANDBOX/proj"
  # Force timeout to 1 second so test isn't slow
  PP_MEMORY_LOCK_TIMEOUT_S=1 run pp_memory_lock "$SANDBOX/proj"
  [ "$status" -ne 0 ]
  pp_memory_unlock "$SANDBOX/proj"
}

@test "lock: stale lock taken over after PP_MEMORY_LOCK_STALE_S" {
  mkdir -p "$SANDBOX/proj/.maint.lock"
  # Backdate it
  touch -t 202001010000 "$SANDBOX/proj/.maint.lock"
  PP_MEMORY_LOCK_STALE_S=60 run pp_memory_lock "$SANDBOX/proj"
  [ "$status" -eq 0 ]
  pp_memory_unlock "$SANDBOX/proj"
}
