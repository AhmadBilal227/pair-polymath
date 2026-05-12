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
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
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
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
  [ -f "$out_dir/gate-summary.json" ]
  rm -rf "$out_dir"
}

@test "eval-gate: v0.4 — gate-summary.json records score_mode field" {
  run "$GATE" --heuristic --dry-mode
  [ "$status" -eq 0 ]
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
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
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
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
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
  [ -n "$out_dir" ]
  [ -f "$out_dir/gate-summary.json" ]
  mode=$(jq -r '.score_mode' "$out_dir/gate-summary.json")
  [ "$mode" = "llm" ]
  # R3.19: when score-report is absent AND baseline_n=0, gate now emits
  # INSUFFICIENT_DATA (not FAIL) because n < 3 threshold. The earlier test
  # expected FAIL; this is the correct verdict for sparse-data runs.
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  case "$verdict" in
    INSUFFICIENT_DATA|FAIL) ;;
    *) printf 'expected INSUFFICIENT_DATA or FAIL, got %s\n' "$verdict" >&3; false ;;
  esac
  rm -rf "$TMPROOT"
}

# R3.19 — two paths to PASS. The original v0.3 criterion (warm_useful >=
# base_useful + 5pp) is Path A. The new v0.4 criterion (hallucinated drop
# >= 5pp AND non-regressing useful) is Path B. Either triggers PASS.

# Helper used by R3.19 tests: stage a shadow tree where the stub run-eval.sh
# branches on PP_MEMORY_ENABLE so baseline / cold / warm produce DIFFERENT
# cycle-output files. The heuristic scorer then yields cohort-specific
# useful% / hallucinated%.
_r319_setup() {
  TMPROOT=$(mktemp -d)
  mkdir -p "$TMPROOT/test/eval/fixtures" "$TMPROOT/test/eval/golden" "$TMPROOT/test/eval/baselines"
  cp "$PP_ROOT/test/eval/run-memory-gate.sh" "$TMPROOT/test/eval/run-memory-gate.sh"
  chmod +x "$TMPROOT/test/eval/run-memory-gate.sh"
  mkdir -p "$TMPROOT/lib/memory"
  ln -s "$PP_ROOT/lib/memory/lock.sh" "$TMPROOT/lib/memory/lock.sh"
  # The real file the heuristic citation regex resolves against:
  # _repo_root is computed relative to run-memory-gate.sh, so
  # $TMPROOT/lib/memory/lock.sh becomes the "real" path the scorer can find.
}

@test "eval-gate: R3.19 — PASS via Path A (useful_delta) when warm useful jumps" {
  _r319_setup
  cat > "$TMPROOT/test/eval/run-eval.sh" <<'EOF'
#!/usr/bin/env bash
runs_dir=""
while [ $# -gt 0 ]; do
  case "$1" in --runs-dir) runs_dir="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$runs_dir"
# Pad >100 chars so the heuristic considers each file scorable.
PAD=$(printf 'p%.0s' $(seq 1 120))
if [ "${PP_MEMORY_ENABLE:-0}" = "1" ]; then
  # warm: 4/4 cycles cite real path → 100% useful, 0% hallucinated
  for i in 1 2 3 4; do
    echo "$PAD lib/memory/lock.sh:$i cite real" > "$runs_dir/cycle-$i.txt"
  done
else
  # baseline: 1/4 cycles cite real, 3 too short → 25% useful, 0% hallucinated
  echo "$PAD lib/memory/lock.sh:7 cite real" > "$runs_dir/cycle-1.txt"
  echo "$PAD other content no citation" > "$runs_dir/cycle-2.txt"
  echo "$PAD other content no citation" > "$runs_dir/cycle-3.txt"
  echo "$PAD other content no citation" > "$runs_dir/cycle-4.txt"
fi
EOF
  chmod +x "$TMPROOT/test/eval/run-eval.sh"

  run "$TMPROOT/test/eval/run-memory-gate.sh" --no-dry --heuristic
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
  [ -f "$out_dir/gate-summary.json" ]
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  pass_path=$(jq -r '.pass_path' "$out_dir/gate-summary.json")
  [ "$verdict" = "PASS" ]
  [ "$pass_path" = "useful_delta" ]
  rm -rf "$TMPROOT"
}

@test "eval-gate: R3.19 — PASS via Path B (hallucinated_delta) when halluc drops 5pp+ with non-regressing useful" {
  _r319_setup
  cat > "$TMPROOT/test/eval/run-eval.sh" <<'EOF'
#!/usr/bin/env bash
runs_dir=""
while [ $# -gt 0 ]; do
  case "$1" in --runs-dir) runs_dir="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$runs_dir"
PAD=$(printf 'p%.0s' $(seq 1 120))
if [ "${PP_MEMORY_ENABLE:-0}" = "1" ]; then
  # warm: 4/4 cycles cite real path → 100% useful, 0% hallucinated
  for i in 1 2 3 4; do
    echo "$PAD lib/memory/lock.sh:$i cite real" > "$runs_dir/cycle-$i.txt"
  done
else
  # baseline: 4/4 cite real AND 4/4 cite fake → 100% useful, 100% hallucinated
  for i in 1 2 3 4; do
    echo "$PAD lib/memory/lock.sh:$i cite real AND not/real/file.ts:99 cite fake" > "$runs_dir/cycle-$i.txt"
  done
fi
EOF
  chmod +x "$TMPROOT/test/eval/run-eval.sh"

  run "$TMPROOT/test/eval/run-memory-gate.sh" --no-dry --heuristic
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
  [ -f "$out_dir/gate-summary.json" ]
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  pass_path=$(jq -r '.pass_path' "$out_dir/gate-summary.json")
  # Baseline halluc=100, warm halluc=0 → drop 100pp (≥5). Both useful=100 (non-regress).
  # Path A useful_delta = 0 (100-100), fails. Path B succeeds → PASS.
  [ "$verdict" = "PASS" ]
  [ "$pass_path" = "hallucinated_delta" ]
  rm -rf "$TMPROOT"
}

@test "eval-gate: R3.19 — FAIL when neither path satisfied (no useful jump, no halluc drop)" {
  _r319_setup
  cat > "$TMPROOT/test/eval/run-eval.sh" <<'EOF'
#!/usr/bin/env bash
runs_dir=""
while [ $# -gt 0 ]; do
  case "$1" in --runs-dir) runs_dir="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$runs_dir"
PAD=$(printf 'p%.0s' $(seq 1 120))
# All cohorts identical: 1/4 useful, 0/4 halluc. No deltas in either direction.
echo "$PAD lib/memory/lock.sh:7 cite real" > "$runs_dir/cycle-1.txt"
echo "$PAD nothing here" > "$runs_dir/cycle-2.txt"
echo "$PAD nothing here" > "$runs_dir/cycle-3.txt"
echo "$PAD nothing here" > "$runs_dir/cycle-4.txt"
EOF
  chmod +x "$TMPROOT/test/eval/run-eval.sh"

  run "$TMPROOT/test/eval/run-memory-gate.sh" --no-dry --heuristic
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  pass_path=$(jq -r '.pass_path' "$out_dir/gate-summary.json")
  # Note: at n=4 (4 cycles per cohort) the dynamic threshold ramps to 15pp,
  # so even a moderate delta wouldn't trigger PASS — but here both cohorts
  # are identical so the verdict is FAIL on the no_pass_path failure mode
  # OR INSUFFICIENT_DATA if n is below the floor.
  case "$verdict" in
    FAIL|INSUFFICIENT_DATA) ;;
    *) printf 'expected FAIL or INSUFFICIENT_DATA, got %s\n' "$verdict" >&3; false ;;
  esac
  # Tightened from previous "" OR "null" — heredoc always emits the field
  # (code-reviewer I1 / I2). jq -r on "" returns "" not "null".
  [ "$pass_path" = "" ]
  rm -rf "$TMPROOT"
}

@test "eval-gate: R3.19 — FAIL on Path B if useful REGRESSES even with halluc drop" {
  _r319_setup
  cat > "$TMPROOT/test/eval/run-eval.sh" <<'EOF'
#!/usr/bin/env bash
runs_dir=""
while [ $# -gt 0 ]; do
  case "$1" in --runs-dir) runs_dir="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$runs_dir"
PAD=$(printf 'p%.0s' $(seq 1 120))
if [ "${PP_MEMORY_ENABLE:-0}" = "1" ]; then
  # warm: 0/4 useful (no real cites), 0/4 hallucinated
  for i in 1 2 3 4; do
    echo "$PAD plain text no cite" > "$runs_dir/cycle-$i.txt"
  done
else
  # baseline: 4/4 useful AND 4/4 hallucinated
  for i in 1 2 3 4; do
    echo "$PAD lib/memory/lock.sh:$i cite real AND not/real/file.ts:99 cite fake" > "$runs_dir/cycle-$i.txt"
  done
fi
EOF
  chmod +x "$TMPROOT/test/eval/run-eval.sh"

  run "$TMPROOT/test/eval/run-memory-gate.sh" --no-dry --heuristic
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  pass_path=$(jq -r '.pass_path' "$out_dir/gate-summary.json")
  # Path B requires non-regression in useful: baseline=100, warm=0 → useful regressed.
  # Path A also fails (warm < base + 5). Verdict FAIL.
  [ "$verdict" = "FAIL" ]
  # R3.19 code-reviewer I2: symmetric pass_path assertion on FAIL paths.
  [ "$pass_path" = "" ]
  rm -rf "$TMPROOT"
}

@test "eval-gate: R3.19 — INSUFFICIENT_DATA when baseline n < 3" {
  _r319_setup
  # Stub emits only 2 cycle files total (< the n=3 floor).
  cat > "$TMPROOT/test/eval/run-eval.sh" <<'EOF'
#!/usr/bin/env bash
runs_dir=""
while [ $# -gt 0 ]; do
  case "$1" in --runs-dir) runs_dir="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$runs_dir"
PAD=$(printf 'p%.0s' $(seq 1 120))
# Only 2 cycles → below the n=3 floor → INSUFFICIENT_DATA expected.
echo "$PAD lib/memory/lock.sh:7 cite real" > "$runs_dir/cycle-1.txt"
echo "$PAD lib/memory/lock.sh:8 cite real" > "$runs_dir/cycle-2.txt"
EOF
  chmod +x "$TMPROOT/test/eval/run-eval.sh"

  run "$TMPROOT/test/eval/run-memory-gate.sh" --no-dry --heuristic
  out_dir=$(printf '%s\n' "$output" | grep -E '^[[:space:]]+Output: ' | head -1 | awk -F': ' '{print $2}')
  verdict=$(jq -r '.verdict' "$out_dir/gate-summary.json")
  baseline_n=$(jq -r '.baseline_n' "$out_dir/gate-summary.json")
  [ "$verdict" = "INSUFFICIENT_DATA" ]
  [ "$baseline_n" -lt 3 ]
  rm -rf "$TMPROOT"
}
