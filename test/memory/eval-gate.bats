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

@test "eval-gate: F2 — gate-summary.json explains heuristic limitation" {
  run "$GATE" --dry-mode
  [ "$status" -eq 0 ]
  out_dir=$(printf '%s\n' "$output" | grep -E '^\s+Output: ' | head -1 | awk -F': ' '{print $2}')
  # Header docstring documents the heuristic.
  head -40 "$GATE" | grep -q "HEURISTIC LIMITATION"
  # Doc reference exists in repo.
  doc="$PP_ROOT/docs/memory-architecture.md"
  grep -q "HEURISTIC" "$doc"
  rm -rf "$out_dir"
}

@test "eval-gate: F2 — --no-dry path runs score loop and emits real verdict" {
  # We can't actually invoke run-eval.sh in a hermetic test (LLM cost,
  # ~minutes). Stage a shadow copy of test/eval/ that has a stub run-eval.sh
  # writing placeholder cycle files. The gate computes its verdict from
  # those per-cycle outputs, so the verdict mechanism runs end-to-end.
  TMPROOT=$(mktemp -d)
  mkdir -p "$TMPROOT/test/eval/fixtures" "$TMPROOT/test/eval/golden" "$TMPROOT/test/eval/baselines"
  # Real gate script — same file the production CI runs.
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
# 3 cycle outputs: 1 useful (real path), 1 hallucinated (fake path),
# 1 too-short (skipped). The real path must exist under the gate's
# expected repo root — lib/memory/lock.sh ships in every Pair Polymath tree.
echo "issue at lib/memory/lock.sh:7 — real cite" > "$runs_dir/cycle-1.txt"
echo "issue at not/a/real/file.ts:42 — fake cite" > "$runs_dir/cycle-2.txt"
echo "x" > "$runs_dir/cycle-3.txt"
EOF
  chmod +x "$TMPROOT/test/eval/run-eval.sh"
  # The gate resolves $_repo_root as $(cd $_dir/../.. && pwd). For the stub
  # repo to have lib/memory/lock.sh, symlink it.
  mkdir -p "$TMPROOT/lib/memory"
  ln -s "$PP_ROOT/lib/memory/lock.sh" "$TMPROOT/lib/memory/lock.sh"

  run "$TMPROOT/test/eval/run-memory-gate.sh" --no-dry
  out_dir=$(printf '%s\n' "$output" | grep -E '^\s+Output: ' | head -1 | awk -F': ' '{print $2}')
  [ -n "$out_dir" ]
  [ -f "$out_dir/gate-summary.json" ]
  # Verdict must be PASS or FAIL — NOT INFRA_PASS.
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  [ "$verdict" != "INFRA_PASS" ]
  [ "$verdict" = "PASS" ] || [ "$verdict" = "FAIL" ]
  # baseline/warm useful% fields must be present (numeric).
  bu=$(jq -r '.baseline_useful_pct' "$out_dir/gate-summary.json")
  wu=$(jq -r '.warm_useful_pct' "$out_dir/gate-summary.json")
  [ -n "$bu" ] && [ "$bu" != "null" ]
  [ -n "$wu" ] && [ "$wu" != "null" ]
  rm -rf "$TMPROOT"
}
