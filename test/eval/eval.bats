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
  TRACE_SCORE="$EVAL_DIR/trace-score.sh"
  # Isolated runs dir per test so concurrent bats workers don't race.
  TMP_RUNS=$(mktemp -d "${TMPDIR:-/tmp}/pp-eval-bats.XXXXXX")
}

teardown() {
  # P2.5 Track 4: race-tolerant cleanup. On Linux CI, the eval harness's
  # async log writers occasionally write to the runs dir after teardown
  # begins → `rm: Directory not empty`. Retry up to 3 times with sleep.
  [ -z "$TMP_RUNS" ] && return 0
  [ ! -d "$TMP_RUNS" ] && return 0
  _retry=0
  while [ "$_retry" -lt 3 ] && [ -d "$TMP_RUNS" ]; do
    rm -rf "$TMP_RUNS" 2>/dev/null
    [ ! -d "$TMP_RUNS" ] && break
    sleep 1
    _retry=$((_retry + 1))
  done
  # Last-resort fallback: find -delete + rmdir (handles partial trees).
  if [ -d "$TMP_RUNS" ]; then
    find "$TMP_RUNS" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$TMP_RUNS" 2>/dev/null || true
  fi
}

@test "eval: run-eval.sh exists and is executable" {
  [ -x "$RUN_EVAL" ]
}

@test "eval: score.sh exists and is executable" {
  [ -x "$SCORE" ]
}

@test "eval: trace-score.sh exists and is executable" {
  [ -x "$TRACE_SCORE" ]
}

@test "eval: run-eval.sh --help exits 0 and prints usage" {
  run bash "$RUN_EVAL" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'Replays each fixture'
  echo "$output" | grep -q -- '--allow-errors'
}

@test "eval: score.sh --help exits 0 and prints usage" {
  run bash "$SCORE" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'eval scorer'
}

@test "eval: trace-score.sh --help exits 0 and prints usage" {
  run bash "$TRACE_SCORE" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'deterministic eval trace reporter'
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

@test "eval: fixture lenses-enabled.txt activates expanded workforce lenses" {
  run bash "$RUN_EVAL" --fixture session-02 --dry-run --runs-dir "$TMP_RUNS"
  [ "$status" -eq 0 ]
  run_dir=$(find "$TMP_RUNS" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -f "$run_dir/session-02.observations.txt" ]
  line_count=$(wc -l < "$run_dir/session-02.observations.txt" | tr -d ' ')
  [ "$line_count" -eq 4 ]
  cut -d'|' -f1 "$run_dir/session-02.observations.txt" | grep -qxF 'CFO'
  cut -d'|' -f1 "$run_dir/session-02.observations.txt" | grep -qxF 'PRE_MORTEM'
  cut -d'|' -f1 "$run_dir/session-02.observations.txt" | grep -qxF 'HISTORIAN'
  cut -d'|' -f1 "$run_dir/session-02.observations.txt" | grep -qxF 'DATABASE_ENGINEER'
}

@test "eval: run-eval.sh writes run-summary.json with the documented schema" {
  bash "$RUN_EVAL" --fixture session-01 --dry-run --runs-dir "$TMP_RUNS"
  run_dir=$(find "$TMP_RUNS" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -f "$run_dir/run-summary.json" ]
  # Top-level keys
  jq -e '.run_ts and .fixtures_processed and .errors_per_fixture and .total_observations
         and .trace_rows_per_fixture and (.total_trace_rows != null)' \
    "$run_dir/run-summary.json"
}

@test "eval: run-eval.sh preserves trace rows when a cycle runs" {
  fakebin=$(mktemp -d "${TMPDIR:-/tmp}/pp-eval-fakebin.XXXXXX")
  printf '#!/bin/sh\nprintf "SILENT\\n"\n' > "$fakebin/llm"
  chmod +x "$fakebin/llm"

  PATH="$fakebin:$PATH" bash "$RUN_EVAL" --fixture session-01 --runs-dir "$TMP_RUNS"
  run_dir=$(find "$TMP_RUNS" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -f "$run_dir/session-01.trace.jsonl" ]
  [ -f "$run_dir/trace.jsonl" ]
  jq -e '
    .fixture == "session-01"
    and .mode.eval_mode == true
    and .router.decision_source == "eval_bypass"
    and .router.shadow_scoring_mode == "scorable_shadow"
    and (.router.shadow_picked_lenses | type == "array")
    and .prompt_versions["analyst-primary"] == "0.5.4.0"
    and .privacy.raw_transcript_archived == false
  ' "$run_dir/trace.jsonl" >/dev/null
  jq -e '.trace_rows_per_fixture["session-01"] >= 1 and .total_trace_rows >= 1' \
    "$run_dir/run-summary.json" >/dev/null
  rm -rf "$fakebin"
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

@test "eval: trace-score.sh reports prompt versions, privacy, eval bypass, and missing goldens" {
  run_dir="$TMP_RUNS/manual-trace"
  mkdir -p "$run_dir"
  printf 'manual-trace\n' > "$TMP_RUNS/latest"
  cat > "$run_dir/custom.observations.txt" <<'EOF'
ENGINEERING|||||||
UNKNOWN_LENS|||||||
EOF
  cat > "$run_dir/trace.jsonl" <<'EOF'
{"fixture":"custom","mode":{"eval_mode":true},"prompt_versions":{"router":"0.5.4.1","analyst-primary":"0.5.4.0"},"router":{"decision_source":"eval_bypass","picked_count":7},"cycle":{"lens_count":7},"privacy":{"raw_transcript_archived":false,"grounded_facts_archived":false,"observation_bodies_archived":false,"payload_previews_archived":false}}
EOF

  run bash "$TRACE_SCORE" --run manual-trace --runs-dir "$TMP_RUNS" --offline
  [ "$status" -eq 0 ]
  [ -f "$run_dir/trace-report.json" ]
  jq -e '
    .total_trace_rows == 1
    and .prompt_versions_seen.router == "0.5.4.1"
    and .trace_rows_per_fixture.custom == 1
    and .privacy.all_flags_false == true
    and .privacy.violation_count == 0
    and .router_scoring_mode == "unscorable_eval_bypass"
    and .router_expected_missing_count == 1
    and .picked_count_vs_lens_count.mismatched_rows == 0
    and .missing_golden_count_by_fixture.custom == 2
    and .missing_golden_total == 2
  ' "$run_dir/trace-report.json" >/dev/null
}

@test "eval: trace-score.sh reports router shadow misses against expectations" {
  run_dir="$TMP_RUNS/manual-router-miss"
  mkdir -p "$run_dir"
  printf 'manual-router-miss\n' > "$TMP_RUNS/latest"
  cat > "$run_dir/session-01.observations.txt" <<'EOF'
ENGINEERING|||||||
PERF_FINOPS|||||||
COGNITIVE_FLOW|||||||
EOF
  cat > "$run_dir/trace.jsonl" <<'EOF'
{"fixture":"session-01","mode":{"eval_mode":true},"prompt_versions":{"router":"0.5.4.1"},"router":{"decision_source":"eval_bypass","picked_count":7,"shadow_scoring_mode":"scorable_shadow","shadow_picked_lenses":["ENGINEERING","PERF_FINOPS"],"shadow_picked_count":2},"cycle":{"lens_count":7},"privacy":{"raw_transcript_archived":false,"grounded_facts_archived":false,"observation_bodies_archived":false,"payload_previews_archived":false}}
EOF

  run bash "$TRACE_SCORE" --run manual-router-miss --runs-dir "$TMP_RUNS" --offline
  [ "$status" -eq 0 ]
  jq -e '
    .router_target_count == 3
    and .router_miss_count == 1
    and (.router_target_recall > 0.66 and .router_target_recall < 0.67)
    and (.router_misses_by_fixture["session-01"] | index("COGNITIVE_FLOW") != null)
    and .unscorable_router_rows == 0
  ' "$run_dir/trace-report.json" >/dev/null
}

@test "eval: trace-score.sh reports router expectations without trace as unscorable" {
  run_dir="$TMP_RUNS/manual-no-trace"
  mkdir -p "$run_dir"
  printf 'manual-no-trace\n' > "$TMP_RUNS/latest"
  cat > "$run_dir/session-01.observations.txt" <<'EOF'
ENGINEERING|||||||
PERF_FINOPS|||||||
COGNITIVE_FLOW|||||||
EOF

  run bash "$TRACE_SCORE" --run manual-no-trace --runs-dir "$TMP_RUNS" --offline
  [ "$status" -eq 0 ]
  jq -e '
    .total_trace_rows == 0
    and .router_target_count == 0
    and .router_miss_count == 0
    and .router_target_recall == null
    and .router_expected_missing_count == 0
    and .unscorable_router_rows == 1
  ' "$run_dir/trace-report.json" >/dev/null
}

@test "eval: trace-score.sh reports perfect router shadow recall" {
  run_dir="$TMP_RUNS/manual-router-hit"
  mkdir -p "$run_dir"
  printf 'manual-router-hit\n' > "$TMP_RUNS/latest"
  cat > "$run_dir/session-01.observations.txt" <<'EOF'
ENGINEERING|||||||
PERF_FINOPS|||||||
COGNITIVE_FLOW|||||||
EOF
  cat > "$run_dir/trace.jsonl" <<'EOF'
{"fixture":"session-01","mode":{"eval_mode":true},"prompt_versions":{"router":"0.5.4.1"},"router":{"decision_source":"eval_bypass","picked_count":7,"shadow_scoring_mode":"scorable_shadow","shadow_picked_lenses":["ENGINEERING","PERF_FINOPS","COGNITIVE_FLOW"],"shadow_picked_count":3},"cycle":{"lens_count":7},"privacy":{"raw_transcript_archived":false,"grounded_facts_archived":false,"observation_bodies_archived":false,"payload_previews_archived":false}}
EOF

  run bash "$TRACE_SCORE" --run manual-router-hit --runs-dir "$TMP_RUNS" --offline
  [ "$status" -eq 0 ]
  jq -e '
    .router_target_count == 3
    and .router_miss_count == 0
    and .router_target_recall == 1
    and (.router_misses_by_fixture["session-01"] | length) == 0
  ' "$run_dir/trace-report.json" >/dev/null
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

@test "eval: score.sh treats no-golden silent rows as unscored, not missing" {
  run_dir="$TMP_RUNS/manual-no-golden"
  mkdir -p "$run_dir"
  printf 'manual-no-golden\n' > "$TMP_RUNS/latest"
  cat > "$run_dir/custom-no-golden.observations.txt" <<'EOF'
ENGINEERING|||||||
EOF

  run bash "$SCORE" --offline --runs-dir "$TMP_RUNS"
  [ "$status" -eq 0 ]
  jq -e '
    .fixtures[0].lenses.ENGINEERING.verdict == "unscored"
    and .per_lens.ENGINEERING.unscored == 1
    and .per_lens.ENGINEERING.missing == 0
  ' "$run_dir/score-report.json" >/dev/null
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
  # Count the enabled lens set, not every lens file. Activation added
  # foothold lenses that are available but not part of the default legacy
  # active set unless lenses-enabled.txt selects them.
  expected_count=$(HOME="$sandbox" CLAUDE_DIR="$sandbox/.claude" \
    PP_CACHE_DIR="$sandbox/.claude/cache" PP_STATE_DIR="$sandbox/.claude/pair-polymath" \
    bash -c '. "$1/lib/config.sh"; . "$1/lib/lens-loader.sh"; pp_load_lenses >/dev/null || exit 1; printf "%s\n" "$PP_LENS_COUNT"' _ "$REPO_ROOT")
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
