#!/usr/bin/env bats
# Budget atomicity + reservation invariants.

setup() {
  PP_CACHE_DIR="$(mktemp -d)"
  export PP_CACHE_DIR
  export PP_MAX_DAILY_CALLS=10000
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../lib/budget.sh"
}

teardown() {
  rm -rf "$PP_CACHE_DIR"
}

@test "budget_inc: 100 parallel writers all increment correctly" {
  local pids=()
  for _ in $(seq 1 100); do
    (budget_inc) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  local final
  final=$(budget_get)
  [ "$final" -eq 100 ]
}

@test "budget_reserve: succeeds when under cap" {
  echo 0 > "$PP_BUDGET_FILE"
  run budget_reserve 23
  [ "$status" -eq 0 ]
  [ "$(budget_get)" -eq 23 ]
}

@test "budget_reserve: refuses when would exceed cap" {
  export PP_MAX_DAILY_CALLS=20
  echo 0 > "$PP_BUDGET_FILE"
  run budget_reserve 23
  [ "$status" -eq 1 ]
  [ "$(budget_get)" -eq 0 ]   # no increment on refusal
}

@test "budget_reserve: at exact cap is permitted" {
  export PP_MAX_DAILY_CALLS=23
  echo 0 > "$PP_BUDGET_FILE"
  run budget_reserve 23
  [ "$status" -eq 0 ]
  [ "$(budget_get)" -eq 23 ]
}
