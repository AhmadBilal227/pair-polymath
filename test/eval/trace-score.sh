#!/usr/bin/env bash
# Pair Polymath - deterministic eval trace reporter.
#
# Reads bounded trace rows from test/eval/runs/<ts>/trace.jsonl and writes
# test/eval/runs/<ts>/trace-report.json. This is offline by design: it reports
# prompt-version lineage, privacy flags, eval-router scoring mode, picked-count
# shape, and golden coverage gaps without making LLM calls.
#
# Flags:
#   --run <ts>      Report this run timestamp (default: latest)
#   --runs-dir <p>  Override runs dir
#   --offline       Accepted for parity with score.sh; no effect
#   --help          This message
#
# Bash 3.2 portable.

set -e -u

_eval_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_runs_dir="$_eval_dir/runs"
_golden_dir="$_eval_dir/golden"
_fixtures_dir="$_eval_dir/fixtures"
target_run=""
offline=0

while [ $# -gt 0 ]; do
  case "$1" in
    --run) shift; target_run="${1:-}" ;;
    --runs-dir) shift; _runs_dir="${1:-$_runs_dir}" ;;
    --offline) offline=1 ;;
    --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'trace-score.sh: unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if ! command -v jq >/dev/null 2>&1; then
  printf 'trace-score.sh: jq is required\n' >&2
  exit 1
fi

if [ -z "$target_run" ]; then
  if [ -f "$_runs_dir/latest" ]; then
    target_run=$(cat "$_runs_dir/latest")
  fi
fi
if [ -z "$target_run" ] || [ ! -d "$_runs_dir/$target_run" ]; then
  printf 'trace-score.sh: no run found (looked for %s/%s)\n' "$_runs_dir" "$target_run" >&2
  exit 1
fi

run_dir="$_runs_dir/$target_run"
trace_file="$run_dir/trace.jsonl"
_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/pp-eval-trace-score.XXXXXX")
trap 'rm -rf "$_tmp_dir" 2>/dev/null || true' EXIT

trace_input="$trace_file"
if [ ! -s "$trace_input" ]; then
  trace_input="$_tmp_dir/trace.jsonl"
  : > "$trace_input"
  for f in "$run_dir"/*.trace.jsonl; do
    [ -f "$f" ] || continue
    fix_name=$(basename "$f" .trace.jsonl)
    jq -c --arg fixture "$fix_name" '. + {fixture: (.fixture // $fixture)}' "$f" >> "$trace_input"
  done
fi

missing_tsv="$_tmp_dir/missing-goldens.tsv"
: > "$missing_tsv"
for obs_file in "$run_dir"/*.observations.txt; do
  [ -f "$obs_file" ] || continue
  fix_name=$(basename "$obs_file" .observations.txt)
  count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    lens="${line%%|||*}"
    [ -n "$lens" ] || continue
    [ -f "$_golden_dir/$fix_name/${lens}.txt" ] || count=$((count + 1))
  done < "$obs_file"
  printf '%s\t%d\n' "$fix_name" "$count" >> "$missing_tsv"
done

missing_json=$(jq -Rn '
  [inputs | select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)}]
  | from_entries
' "$missing_tsv")
missing_total=$(printf '%s' "$missing_json" | jq '[.[]] | add // 0')

router_expectations="$_tmp_dir/router-expectations.jsonl"
: > "$router_expectations"
router_fixtures=$(jq -r '.fixture // empty' "$trace_input" 2>/dev/null | LC_ALL=C sort -u)
while IFS= read -r fix_name; do
  [ -n "$fix_name" ] || continue
  expected_file="$_fixtures_dir/$fix_name/router.expected.json"
  if [ -f "$expected_file" ] && jq empty "$expected_file" >/dev/null 2>&1; then
    jq -c --arg fixture "$fix_name" '
      {
        fixture: $fixture,
        exists: true,
        must_pick: ((.must_pick // []) | map(select(type == "string"))),
        nice_to_pick: ((.nice_to_pick // []) | map(select(type == "string")))
      }
    ' "$expected_file" >> "$router_expectations"
  else
    jq -nc --arg fixture "$fix_name" '{fixture: $fixture, exists: false, must_pick: [], nice_to_pick: []}' \
      >> "$router_expectations"
  fi
done <<EOF
$router_fixtures
EOF

trace_summary=$(jq -sc '
  def privacy_ok:
    (.privacy.raw_transcript_archived == false)
    and (.privacy.grounded_facts_archived == false)
    and (.privacy.observation_bodies_archived == false)
    and (.privacy.payload_previews_archived == false);
  {
    total_trace_rows: length,
    prompt_versions_seen: (map(.prompt_versions // {}) | reduce .[] as $pv ({}; . * $pv)),
    trace_rows_per_fixture: (
      group_by(.fixture // "unknown")
      | map({key: (.[0].fixture // "unknown"), value: length})
      | from_entries
    ),
    privacy: {
      all_flags_false: all(.[]; privacy_ok),
      violation_count: ([.[] | select(privacy_ok | not)] | length)
    },
    picked_count_vs_lens_count: {
      mismatched_rows: ([.[] | select((.router.picked_count // -1) != (.cycle.lens_count // -2))] | length),
      rows: map({
        fixture: (.fixture // "unknown"),
        picked_count: (.router.picked_count // null),
        lens_count: (.cycle.lens_count // null),
        decision_source: (.router.decision_source // "unknown")
      })
    },
    router_scoring_mode: (
      if any(.[]; (.mode.eval_mode == true) or (.router.decision_source == "eval_bypass"))
      then "unscorable_eval_bypass"
      else "scorable_runtime_router"
      end
    )
  }
' "$trace_input")

router_summary=$(jq -sc --slurpfile expected "$router_expectations" '
  ($expected // []) as $expectations
  | def exp_for($fixture):
      ($expectations | map(select(.fixture == $fixture)) | .[0] // {exists:false,must_pick:[]});
  def row_eval:
    . as $row
    | ($row.fixture // "unknown") as $fixture
    | exp_for($fixture) as $exp
    | ($row.router.shadow_picked_lenses // []) as $picked
    | {
        fixture: $fixture,
        expected_exists: ($exp.exists == true),
        scorable: (($exp.exists == true) and ($row.router.shadow_scoring_mode == "scorable_shadow") and (($picked | type) == "array")),
        target_count: (($exp.must_pick // []) | length),
        misses: (($exp.must_pick // []) | map(select(. as $target | ($picked | index($target)) == null)))
      };
  (map(row_eval)) as $rows
  | ($rows | map(select(.expected_exists and (.scorable | not))) | length) as $unscorable
  | ($rows | map(select(.expected_exists and .scorable))) as $scored
  | ($scored | map(.target_count) | add // 0) as $target_total
  | ($scored | map(.misses | length) | add // 0) as $miss_total
  | {
      router_target_recall: (if $target_total == 0 then null else (($target_total - $miss_total) / $target_total) end),
      router_target_count: $target_total,
      router_miss_count: $miss_total,
      router_misses_by_fixture: (
        $scored
        | group_by(.fixture)
        | map({key: .[0].fixture, value: (map(.misses[]) | unique)})
        | from_entries
      ),
      router_expected_missing_count: ($rows | map(select(.expected_exists | not)) | length),
      unscorable_router_rows: $unscorable
    }
' "$trace_input")

generated_at=$(date -u +%Y%m%dT%H%M%SZ)
report_path="$run_dir/trace-report.json"
report_tmp="${report_path}.tmp.$$"
jq -n \
  --arg run_ts "$target_run" \
  --arg generated_at "$generated_at" \
  --argjson offline "$offline" \
  --argjson trace "$trace_summary" \
  --argjson router "$router_summary" \
  --argjson missing "$missing_json" \
  --argjson missing_total "$missing_total" \
  '{
    run_ts: $run_ts,
    generated_at: $generated_at,
    offline: $offline
  } + $trace + $router + {
    missing_golden_count_by_fixture: $missing,
    missing_golden_total: $missing_total
  }' > "$report_tmp"

jq . "$report_tmp" >/dev/null
mv "$report_tmp" "$report_path"

printf 'trace-score.sh: report written -> %s\n' "$report_path"
