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

@test "lock: F6 — _pp_memory_increment_maint_counter_locked increments + reports" {
  mkdir -p "$SANDBOX/proj"
  # Seed a DB with the cycle_state schema (mirrors what pp_memory_db_init creates).
  sqlite3 "$SANDBOX/proj/observations.sqlite" "CREATE TABLE cycle_state(key TEXT PRIMARY KEY, value TEXT);"
  out1=$(_pp_memory_increment_maint_counter_locked "$SANDBOX/proj" 100)
  [ "$out1" = "1" ]
  out2=$(_pp_memory_increment_maint_counter_locked "$SANDBOX/proj" 100)
  [ "$out2" = "2" ]
}

@test "lock: F6 — counter resets and emits TRIGGER at threshold" {
  mkdir -p "$SANDBOX/proj"
  sqlite3 "$SANDBOX/proj/observations.sqlite" "CREATE TABLE cycle_state(key TEXT PRIMARY KEY, value TEXT); INSERT INTO cycle_state VALUES('maintenance_cycle_counter','11');"
  out=$(_pp_memory_increment_maint_counter_locked "$SANDBOX/proj" 12)
  [ "$out" = "TRIGGER" ]
  cur=$(sqlite3 "$SANDBOX/proj/observations.sqlite" "SELECT value FROM cycle_state WHERE key='maintenance_cycle_counter';")
  [ "$cur" = "0" ]
}

@test "lock: F6 — non-existent DB returns NOOP without crashing" {
  mkdir -p "$SANDBOX/proj"
  out=$(_pp_memory_increment_maint_counter_locked "$SANDBOX/proj" 12)
  [ "$out" = "NOOP" ]
}

@test "lock: F6 — non-numeric threshold falls back to default" {
  mkdir -p "$SANDBOX/proj"
  sqlite3 "$SANDBOX/proj/observations.sqlite" "CREATE TABLE cycle_state(key TEXT PRIMARY KEY, value TEXT); INSERT INTO cycle_state VALUES('maintenance_cycle_counter','11');"
  out=$(_pp_memory_increment_maint_counter_locked "$SANDBOX/proj" 'evil; DROP TABLE cycle_state')
  # Default threshold is 12, current value 11 → +1 = 12 → TRIGGER.
  [ "$out" = "TRIGGER" ]
  # Table must still exist.
  cur=$(sqlite3 "$SANDBOX/proj/observations.sqlite" "SELECT value FROM cycle_state WHERE key='maintenance_cycle_counter';")
  [ "$cur" = "0" ]
}

@test "lock: R3.5 — pp_memory_with_lock preserves caller's INT trap" {
  mkdir -p "$SANDBOX/proj"
  _R3_NOOP() { :; }
  trap 'echo CALLER_INT_FIRED >&2' INT
  caller_before=$(trap -p INT)
  pp_memory_with_lock "$SANDBOX/proj" _R3_NOOP
  caller_after=$(trap -p INT)
  trap - INT
  [ "$caller_before" = "$caller_after" ]
}

@test "lock: R3.5 — pp_memory_with_lock preserves caller's TERM trap" {
  mkdir -p "$SANDBOX/proj"
  _R3_NOOP() { :; }
  trap 'echo CALLER_TERM_FIRED >&2' TERM
  caller_before=$(trap -p TERM)
  pp_memory_with_lock "$SANDBOX/proj" _R3_NOOP
  caller_after=$(trap -p TERM)
  trap - TERM
  [ "$caller_before" = "$caller_after" ]
}

@test "lock: R3.5 — no caller trap → no trap after pp_memory_with_lock" {
  mkdir -p "$SANDBOX/proj"
  _R3_NOOP() { :; }
  trap - INT TERM
  pp_memory_with_lock "$SANDBOX/proj" _R3_NOOP
  [ -z "$(trap -p INT)" ]
  [ -z "$(trap -p TERM)" ]
}
