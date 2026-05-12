#!/usr/bin/env bats
# Pair Polymath — memory eval gate harness (Task D.4).
#
# Verifies the gate script is present, executable, and exits cleanly in
# --dry-mode. We DO NOT run the real eval here (that costs API budget +
# requires recorded goldens); the goal is to catch "deleted by accident"
# or "syntax broken" regressions on every test run.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GATE="$PP_ROOT/test/eval/run-memory-gate.sh"
}

@test "eval-gate: script exists and is executable" {
  [ -f "$GATE" ]
  [ -x "$GATE" ]
}

@test "eval-gate: --help prints usage" {
  run "$GATE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory subsystem eval gate"* ]]
}

@test "eval-gate: --dry-mode exits 0 and writes gate-summary.json" {
  TMPDIR="$(mktemp -d)"
  run "$GATE" --dry-mode
  [ "$status" -eq 0 ]
  # Output dir is under test/eval/runs/memory-gate-<ts>. The script prints
  # the path on stdout.
  out_dir=$(printf '%s\n' "$output" | grep -E '^\s+Output: ' | head -1 | awk -F': ' '{print $2}')
  [ -n "$out_dir" ]
  [ -f "$out_dir/gate-summary.json" ]
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  [ "$verdict" = "INFRA_PASS" ]
  rm -rf "$out_dir"
}

@test "eval-gate: rejects unknown flags" {
  run "$GATE" --bogus-flag
  [ "$status" -ne 0 ]
}
