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
