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

@test "eval-gate: v0.4 — header documents LLM-judge as default scoring mode" {
  # The F2 test was renamed in v0.4 — the gate is now LLM-judge by default
  # (replacing the F2 heuristic-only limitation). The header must explain
  # the methodology so contributors don't re-add the regex scorer.
  run "$GATE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM-judge"* ]]
  [[ "$output" == *"DEFAULT MODE"* ]]
}

@test "eval-gate: v0.4 — --heuristic flag accepted for legacy fast-iteration mode" {
  run "$GATE" --heuristic --dry-mode
  [ "$status" -eq 0 ]
  out_dir=$(printf '%s\n' "$output" | grep -E '^\s+Output: ' | head -1 | awk -F': ' '{print $2}')
  [ -f "$out_dir/gate-summary.json" ]
  rm -rf "$out_dir"
}

@test "eval-gate: v0.4 — gate-summary.json records score_mode field" {
  run "$GATE" --heuristic --dry-mode
  [ "$status" -eq 0 ]
  out_dir=$(printf '%s\n' "$output" | grep -E '^\s+Output: ' | head -1 | awk -F': ' '{print $2}')
  # dry_mode skips the non-dry path entirely so score_mode isn't recorded,
  # but the verdict mechanism shouldn't crash. Real score_mode coverage
  # lives below in the --no-dry path test.
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  [ "$verdict" = "INFRA_PASS" ]
  rm -rf "$out_dir"
}

@test "eval-gate: F2 — --no-dry --heuristic path runs and emits real verdict" {
  # Heuristic path is the v0.3 regex scorer kept for fast local iteration
  # without LLM budget. Same end-to-end mechanism as before; just guarded
  # by --heuristic flag now that LLM-judge is default.
  TMPROOT=$(mktemp -d)
  mkdir -p "$TMPROOT/test/eval/fixtures" "$TMPROOT/test/eval/golden" "$TMPROOT/test/eval/baselines"
  cp "$PP_ROOT/test/eval/run-memory-gate.sh" "$TMPROOT/test/eval/run-memory-gate.sh"
  chmod +x "$TMPROOT/test/eval/run-memory-gate.sh"
  cat > "$TMPROOT/test/eval/run-eval.sh" <<'EOF'
#!/usr/bin/env bash
runs_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --runs-dir) runs_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$runs_dir" ] || exit 0
mkdir -p "$runs_dir"
echo "issue at lib/memory/lock.sh:7 — real cite" > "$runs_dir/cycle-1.txt"
echo "issue at not/a/real/file.ts:42 — fake cite" > "$runs_dir/cycle-2.txt"
echo "x" > "$runs_dir/cycle-3.txt"
EOF
  chmod +x "$TMPROOT/test/eval/run-eval.sh"
  mkdir -p "$TMPROOT/lib/memory"
  ln -s "$PP_ROOT/lib/memory/lock.sh" "$TMPROOT/lib/memory/lock.sh"

  run "$TMPROOT/test/eval/run-memory-gate.sh" --no-dry --heuristic
  out_dir=$(printf '%s\n' "$output" | grep -E '^\s+Output: ' | head -1 | awk -F': ' '{print $2}')
  [ -n "$out_dir" ]
  [ -f "$out_dir/gate-summary.json" ]
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  [ "$verdict" != "INFRA_PASS" ]
  [ "$verdict" = "PASS" ] || [ "$verdict" = "FAIL" ]
  mode=$(jq -r '.score_mode' "$out_dir/gate-summary.json")
  [ "$mode" = "heuristic" ]
  rm -rf "$TMPROOT"
}

@test "eval-gate: v0.4 — --no-dry --llm-judge with no score-report falls through to zeros" {
  # When score.sh hasn't been invoked (e.g., `llm` not on PATH), the
  # LLM-judge path finds no score-report.json and produces 0/0/0 — the
  # gate then evaluates the criteria (0 useful, 0 halluc) and emits a
  # deterministic FAIL (warm useful must be ≥ baseline + 5pp, which 0
  # vs 0 doesn't satisfy). This asserts the gate doesn't crash on a
  # missing score-report.
  TMPROOT=$(mktemp -d)
  mkdir -p "$TMPROOT/test/eval/fixtures" "$TMPROOT/test/eval/golden" "$TMPROOT/test/eval/baselines"
  cp "$PP_ROOT/test/eval/run-memory-gate.sh" "$TMPROOT/test/eval/run-memory-gate.sh"
  chmod +x "$TMPROOT/test/eval/run-memory-gate.sh"
  # Stub run-eval that creates cohort dir but doesn't produce score-report.
  cat > "$TMPROOT/test/eval/run-eval.sh" <<'EOF'
#!/usr/bin/env bash
runs_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --runs-dir) runs_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$runs_dir"
echo "any content" > "$runs_dir/cycle-1.txt"
EOF
  chmod +x "$TMPROOT/test/eval/run-eval.sh"
  # No score.sh either — gate's score_cohort_llm must handle absence gracefully.
  rm -f "$TMPROOT/test/eval/score.sh"
  run "$TMPROOT/test/eval/run-memory-gate.sh" --no-dry --llm-judge
  out_dir=$(printf '%s\n' "$output" | grep -E '^\s+Output: ' | head -1 | awk -F': ' '{print $2}')
  [ -n "$out_dir" ]
  [ -f "$out_dir/gate-summary.json" ]
  mode=$(jq -r '.score_mode' "$out_dir/gate-summary.json")
  [ "$mode" = "llm" ]
  # All zeros → must FAIL (warm useful 0 < baseline useful 0 + 5pp threshold).
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  [ "$verdict" = "FAIL" ]
  rm -rf "$TMPROOT"
}
