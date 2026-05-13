#!/usr/bin/env bats
# Pair Polymath — eval-harness scaffold tests.
#
# These tests intentionally do NOT require an OpenAI key. The scoring path is
# exercised with --offline, and the replay path uses --dry-run. Real scoring
# happens when a human runs `bash test/eval/score.sh` outside CI.

setup() {
  EVAL_DIR="${BATS_TEST_DIRNAME}"
  REPO_ROOT="$(cd "$EVAL_DIR/../.." && pwd)"
  RUN_EVAL="$EVAL_DIR/run-eval.sh"
  SCORE="$EVAL_DIR/score.sh"
  # Isolated runs dir per test so concurrent bats workers don't race.
  TMP_RUNS=$(mktemp -d "${TMPDIR:-/tmp}/pp-eval-bats.XXXXXX")
}

teardown() {
  [ -n "$TMP_RUNS" ] && [ -d "$TMP_RUNS" ] && rm -rf "$TMP_RUNS"
}

@test "eval: run-eval.sh exists and is executable" {
  [ -x "$RUN_EVAL" ]
}

@test "eval: score.sh exists and is executable" {
  [ -x "$SCORE" ]
}

@test "eval: run-eval.sh --help exits 0 and prints usage" {
  run bash "$RUN_EVAL" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'Replays each fixture'
}

@test "eval: score.sh --help exits 0 and prints usage" {
  run bash "$SCORE" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'eval scorer'
}

@test "eval: run-eval.sh --dry-run --all completes cleanly" {
  run bash "$RUN_EVAL" --all --dry-run --runs-dir "$TMP_RUNS"
  [ "$status" -eq 0 ]
  # Must process at least one fixture (session-01 ships in-repo).
  echo "$output" | grep -Eq '[0-9]+ fixture\(s\) processed'
}

@test "eval: run-eval.sh --fixture session-01 --dry-run produces observations.txt" {
  run bash "$RUN_EVAL" --fixture session-01 --dry-run --runs-dir "$TMP_RUNS"
  [ "$status" -eq 0 ]
  # Find the run dir created by this invocation.
  run_dir=$(find "$TMP_RUNS" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$run_dir" ]
  [ -f "$run_dir/session-01.observations.txt" ]
  # 7 lenses → 7 lines in observations.txt
  line_count=$(wc -l < "$run_dir/session-01.observations.txt" | tr -d ' ')
  [ "$line_count" -eq 7 ]
}

@test "eval: run-eval.sh writes run-summary.json with the documented schema" {
  bash "$RUN_EVAL" --fixture session-01 --dry-run --runs-dir "$TMP_RUNS"
  run_dir=$(find "$TMP_RUNS" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -f "$run_dir/run-summary.json" ]
  # Top-level keys
  jq -e '.run_ts and .fixtures_processed and .errors_per_fixture and .total_observations' \
    "$run_dir/run-summary.json"
}

@test "eval: run-eval.sh rejects unknown flag" {
  run bash "$RUN_EVAL" --not-a-flag
  [ "$status" -ne 0 ]
}

@test "eval: score.sh --offline produces score-report.json" {
  bash "$RUN_EVAL" --fixture session-01 --dry-run --runs-dir "$TMP_RUNS"
  run bash "$SCORE" --offline --runs-dir "$TMP_RUNS" --cheap
  [ "$status" -eq 0 ]
  run_dir=$(find "$TMP_RUNS" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -f "$run_dir/score-report.json" ]
}

@test "eval: score-report.json has the documented schema" {
  bash "$RUN_EVAL" --fixture session-01 --dry-run --runs-dir "$TMP_RUNS"
  bash "$SCORE" --offline --runs-dir "$TMP_RUNS"
  run_dir=$(find "$TMP_RUNS" -mindepth 1 -maxdepth 1 -type d | head -1)
  report="$run_dir/score-report.json"
  # Top-level keys present
  jq -e '.run_ts and .scored_at and .scorer_model and .fixtures and .per_lens' "$report"
  # Each per_lens entry has the 6 expected counters
  jq -e '.per_lens | to_entries[] | .value
         | (.useful != null) and (.obvious != null)
           and (.hallucinated != null) and ."missed-better" != null
           and (.missing != null) and (.unscored != null)' "$report"
}

@test "eval: score.sh --offline marks dry-run rows as 'missing' verdict" {
  bash "$RUN_EVAL" --fixture session-01 --dry-run --runs-dir "$TMP_RUNS"
  bash "$SCORE" --offline --runs-dir "$TMP_RUNS"
  run_dir=$(find "$TMP_RUNS" -mindepth 1 -maxdepth 1 -type d | head -1)
  # session-01 has goldens for all 7 lenses, observation is empty in --dry-run,
  # so each lens should be missing=1.
  missing_total=$(jq '[.per_lens | to_entries[] | .value.missing] | add' "$run_dir/score-report.json")
  [ "$missing_total" -eq 7 ]
}

@test "eval: PP_EVAL_MODE emits exactly PP_LENS_COUNT lines from bin/statusline.sh" {
  # Build a minimal sandbox + input.json identical to what run-eval.sh would
  # produce. Tests PP_EVAL_MODE in isolation from the driver.
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/pp-eval-bats-isol.XXXXXX")
  mkdir -p "$sandbox/.claude/cache" "$sandbox/repo"
  trans="$sandbox/transcript.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"hello"}}\n' > "$trans"
  cat > "$sandbox/input.json" <<EOF
{"session_id":"bats-eval","workspace":{"current_dir":"$sandbox/repo"},"model":{"display_name":"S"},"transcript_path":"$trans","cost":{"total_cost_usd":0.0}}
EOF
  run env HOME="$sandbox" CLAUDE_DIR="$sandbox/.claude" \
    PP_CACHE_DIR="$sandbox/.claude/cache" \
    PP_EVAL_MODE=1 PP_EXTERNAL_LLM=0 PP_PARALLEL_INTERVAL_S=1 PP_IDLE_THRESHOLD_S=999999 \
    bash -c "bash '$REPO_ROOT/bin/statusline.sh' < '$sandbox/input.json'"
  [ "$status" -eq 0 ]
  # Read the expected lens count from the registry directly (count .json
  # files in lenses/). Sourcing lib/lens-loader.sh inside `bash -c` was
  # fragile cross-platform — set -u + PP_ROOT scoping made $PP_LENS_COUNT
  # empty on Ubuntu bash 5 even when statusline.sh's own copy worked
  # fine. Counting files is a more direct surrogate for the same value.
  expected_count=$(find "$REPO_ROOT/lenses" -maxdepth 1 -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
  line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  if [ "$line_count" -ne "$expected_count" ]; then
    printf 'line_count=%s expected_count=%s output:\n%s\n' "$line_count" "$expected_count" "$output" >&2
  fi
  [ "$line_count" -eq "$expected_count" ]
  # Every line matches the LENS_ID|||...|||...|||... shape
  printf '%s\n' "$output" | grep -Eq '^[A-Z_]+\|\|\|'
  rm -rf "$sandbox"
}

@test "eval: PP_EVAL_MODE has no effect when unset (normal render path)" {
  # Strict opt-in: with PP_EVAL_MODE unset, the script must NOT emit any
  # line matching the eval-mode `LENS_ID|||...` shape on stdout.
  # R1 code-reviewer H3: previous assertion was `|| skip` which converted
  # any failure into a skip — the test could never fail. Fixed: assert
  # NO line matches the eval shape (positive negative-control).
  run bash -c "echo '{}' | bash '$REPO_ROOT/bin/statusline.sh'"
  [ "$status" -eq 0 ]
  # No line on stdout should look like an eval-mode emission. If one does,
  # PP_EVAL_MODE has leaked into the default path.
  if printf '%s\n' "$output" | grep -Eq '^[A-Z_]+\|\|\|.*\|\|\|.*\|\|\|'; then
    printf 'EVAL_MODE leak detected — stdout has lens-shape lines without PP_EVAL_MODE set:\n%s\n' "$output" >&2
    return 1
  fi
}

# v0.4 calibration harness — R3.19.
@test "eval: calibrate-judge.sh exists and is executable" {
  [ -x "$EVAL_DIR/calibrate-judge.sh" ]
}

@test "eval: calibrate-judge --help exits 0 and prints usage" {
  run bash "$EVAL_DIR/calibrate-judge.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"calibration harness"* ]]
  [[ "$output" == *"--csv"* ]]
}

@test "eval: calibrate-judge --offline scores all rows as unscored, agreement_rate=0" {
  csv="$TMP_RUNS/cal.csv"
  out="$TMP_RUNS/cal.calibration.json"
  cat > "$csv" <<EOFCSV
lens,observation,golden,human_label
ENG,obs with N+1 in handlers,ARCH golden,useful
SEC,unrelated string,SEC golden,missed_better
PERF,prisma findMany,PERF golden,useful
EOFCSV
  run bash "$EVAL_DIR/calibrate-judge.sh" --csv "$csv" --out "$out" --offline
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  # Schema check.
  total=$(jq -r '.total_rows' "$out")
  scored=$(jq -r '.scored_rows' "$out")
  rate=$(jq -r '.agreement_rate' "$out")
  offline=$(jq -r '.offline' "$out")
  [ "$total" = "3" ]
  [ "$scored" = "3" ]
  [ "$rate" = "0.0000" ]
  [ "$offline" = "1" ]
  # Confusion matrix has all 4 human labels as top-level keys.
  jq -e '.confusion | has("useful") and has("obvious") and has("hallucinated") and has("missed_better")' "$out" >/dev/null
}

@test "eval: calibrate-judge rejects missing --csv flag" {
  run bash "$EVAL_DIR/calibrate-judge.sh" --offline
  [ "$status" -ne 0 ]
  [[ "$output" == *"--csv is required"* ]]
}

@test "eval: calibrate-judge skips empty-observation rows" {
  csv="$TMP_RUNS/cal2.csv"
  out="$TMP_RUNS/cal2.calibration.json"
  cat > "$csv" <<EOFCSV
lens,observation,golden,human_label
ENG,non-empty obs,golden,useful
SEC,,golden,useful
PERF,another non-empty,golden,obvious
EOFCSV
  run bash "$EVAL_DIR/calibrate-judge.sh" --csv "$csv" --out "$out" --offline
  [ "$status" -eq 0 ]
  total=$(jq -r '.total_rows' "$out")
  scored=$(jq -r '.scored_rows' "$out")
  # 3 rows in CSV, 1 empty → 2 scored.
  [ "$total" = "3" ]
  [ "$scored" = "2" ]
}

@test "eval: calibrate-judge non-existent CSV exits 1" {
  run bash "$EVAL_DIR/calibrate-judge.sh" --csv /tmp/does-not-exist-$$.csv --offline
  [ "$status" -eq 1 ]
  [[ "$output" == *"CSV not found"* ]]
}

@test "eval: v0.4 Phase 1 useful% delta gate (skip when no baselines)" {
  # Phase 1 plan Task 7. Activates ONLY when both baselines are checked
  # in. Until then this test is a no-op so CI stays green. Capture:
  #   bash test/eval/run-eval.sh --all --out test/eval/runs/v0.4-phase1
  #   bash test/eval/score.sh --runs-dir test/eval/runs/v0.4-phase1 \
  #        --out test/eval/baselines/v0.4-phase1/score-report.json
  # And run against a v0.3.0 baseline likewise stashed at
  # test/eval/baselines/v0.3.0/score-report.json.
  base="$EVAL_DIR/baselines/v0.3.0/score-report.json"
  cur="$EVAL_DIR/baselines/v0.4-phase1/score-report.json"
  [ -f "$base" ] || skip "no v0.3.0 baseline (capture via run-eval.sh + score.sh)"
  [ -f "$cur" ]  || skip "no v0.4-phase1 baseline (Phase 1 gate inactive)"

  : "${PP_EVAL_USEFUL_DELTA_MIN_PP:=5}"
  lenses_improved=0
  lenses_regressed_halluc=0
  while IFS= read -r lens; do
    b_use=$(jq -r --arg l "$lens" '.per_lens[$l].useful // 0' "$base")
    c_use=$(jq -r --arg l "$lens" '.per_lens[$l].useful // 0' "$cur")
    b_hal=$(jq -r --arg l "$lens" '.per_lens[$l].hallucinated // 0' "$base")
    c_hal=$(jq -r --arg l "$lens" '.per_lens[$l].hallucinated // 0' "$cur")
    delta=$(LC_ALL=C awk -v b="$b_use" -v c="$c_use" 'BEGIN{printf "%.1f", c-b}')
    if LC_ALL=C awk -v d="$delta" -v m="$PP_EVAL_USEFUL_DELTA_MIN_PP" 'BEGIN{exit !(d>=m)}'; then
      lenses_improved=$((lenses_improved + 1))
    fi
    # Hallucination must NOT regress beyond a 1pp jitter tolerance.
    if LC_ALL=C awk -v b="$b_hal" -v c="$c_hal" 'BEGIN{exit !(c>b+1)}'; then
      lenses_regressed_halluc=$((lenses_regressed_halluc + 1))
    fi
  done < <(jq -r '.per_lens | keys[]' "$base")

  # Gate per docs/v0.4-intelligence-roadmap.md Phase 1:
  #   useful% delta >=PP_EVAL_USEFUL_DELTA_MIN_PP on >=4 of 7 lenses
  #   AND no lens regresses on hallucination%
  echo "useful%-improved-lenses: $lenses_improved" >&3
  echo "halluc%-regressed-lenses: $lenses_regressed_halluc" >&3
  [ "$lenses_improved" -ge 4 ]
  [ "$lenses_regressed_halluc" -eq 0 ]
}
