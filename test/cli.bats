#!/usr/bin/env bats
# polymath CLI: version, status, help, unknown command.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "polymath version: prints VERSION" {
  run bash "$PP_ROOT/bin/polymath" version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$PP_ROOT/VERSION")" ]
}

@test "polymath status: exits 0 with status info" {
  run bash "$PP_ROOT/bin/polymath" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pair Polymath status"* ]]
  [[ "$output" == *"Lenses loaded:"* ]]
}

@test "polymath help: lists subcommands" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"version"* ]]
}

@test "polymath: no args defaults to status" {
  run bash "$PP_ROOT/bin/polymath"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pair Polymath status"* ]]
}

@test "polymath: unknown command → exit 2 + stderr message" {
  run bash "$PP_ROOT/bin/polymath" nope 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
  [[ "$output" == *"polymath help"* ]]
}
