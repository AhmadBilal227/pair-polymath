#!/usr/bin/env bash
# Pair Polymath — eval harness driver.
#
# Replays each fixture under test/eval/fixtures/ through bin/statusline.sh with
# PP_EVAL_MODE=1 and captures the raw lens observations to
# test/eval/runs/<ts>/<fixture>.observations.txt. When the cycle runs, also
# preserves bounded trace metadata as <fixture>.trace.jsonl and trace.jsonl.
# Emits a JSON run-summary at test/eval/runs/<ts>/run-summary.json.
#
# Flags:
#   --fixture <name>   Run only the named fixture (e.g. session-01)
#   --all              Run every fixture under test/eval/fixtures/ (default)
#   --dry-run          Skip LLM calls (PP_EXTERNAL_LLM=0). Useful in CI without
#                      an OpenAI key. Each lens emits an empty observation row.
#   --runs-dir <path>  Override the run output directory (default
#                      test/eval/runs). Used by bats tests.
#   --help             This message.
#
# Output schema (run-summary.json):
#   { "run_ts": "20260512T...", "fixtures_processed": N,
#     "errors_per_fixture": { "<fixture>": <int>, ... },
#     "total_observations": N,
#     "trace_rows_per_fixture": { "<fixture>": <int>, ... },
#     "total_trace_rows": N }
#
# Bash 3.2 portable. No mapfile, no associative-array sugar.

set -e -u

_eval_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "$_eval_dir/../.." && pwd)"
_statusline="$_repo_root/bin/statusline.sh"
_fixtures_dir="$_eval_dir/fixtures"
_runs_dir="$_eval_dir/runs"

target_fixture=""
run_all=1
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --fixture)
      shift
      target_fixture="${1:-}"
      run_all=0
      ;;
    --all)
      run_all=1
      ;;
    --dry-run)
      dry_run=1
      ;;
    --runs-dir)
      shift
      _runs_dir="${1:-$_runs_dir}"
      ;;
    --help|-h)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      printf 'run-eval.sh: unknown flag: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -x "$_statusline" ]; then
  printf 'run-eval.sh: bin/statusline.sh not found or not executable: %s\n' "$_statusline" >&2
  exit 1
fi
if [ ! -d "$_fixtures_dir" ]; then
  printf 'run-eval.sh: fixtures dir missing: %s\n' "$_fixtures_dir" >&2
  exit 1
fi

# Build the fixture list. Skip README.md and other non-directory entries.
fixtures=""
if [ "$run_all" = "1" ]; then
  for d in "$_fixtures_dir"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    fixtures="${fixtures}${name}
"
  done
else
  if [ -z "$target_fixture" ]; then
    printf 'run-eval.sh: --fixture requires a name\n' >&2
    exit 2
  fi
  if [ ! -d "$_fixtures_dir/$target_fixture" ]; then
    printf 'run-eval.sh: fixture not found: %s\n' "$target_fixture" >&2
    exit 1
  fi
  fixtures="$target_fixture
"
fi

# Trim trailing newline; bail if nothing matched.
fixtures=$(printf '%s' "$fixtures" | sed '/^$/d')
if [ -z "$fixtures" ]; then
  printf 'run-eval.sh: no fixtures to run\n' >&2
  exit 1
fi

# Timestamp + run directory. Use UTC for reproducibility across machines.
run_ts=$(date -u +%Y%m%dT%H%M%SZ)
run_dir="$_runs_dir/$run_ts"
mkdir -p "$run_dir"

# Per-fixture replay loop. Each fixture gets its own sandbox HOME / CLAUDE_DIR
# so cache files don't leak across runs.
fixtures_processed=0
total_observations=0
total_trace_rows=0
errors_json="{"
errors_first=1
trace_rows_json="{"
trace_rows_first=1

for fix in $fixtures; do
  fix_dir="$_fixtures_dir/$fix"
  input_json="$fix_dir/input.json"
  transcript="$fix_dir/transcript.jsonl"

  if [ ! -f "$input_json" ]; then
    printf 'run-eval.sh: %s missing input.json — skipping\n' "$fix" >&2
    continue
  fi

  # Sandbox dir for this fixture's HOME (cache + state). mktemp -d works
  # identically on macOS bash 3.2 and Linux bash 5.
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/pp-eval-$fix.XXXXXX")
  mkdir -p "$sandbox/.claude/cache"

  # The fixture provides a transcript and (optionally) a cwd-state dir. If the
  # input.json references the transcript by an absolute path we leave it; if it
  # references via "@TRANSCRIPT@" or "@CWD@" placeholders we rewrite them.
  input_resolved="$sandbox/input.json"
  cwd_state_dir=""
  if [ -d "$fix_dir/cwd-state" ]; then
    # Copy the fixture's cwd-state into the sandbox and init it as its own
    # git repo. Otherwise `git -C $cwd rev-parse` walks UP and finds the
    # surrounding worktree's git dir, leaking the host repo's files into
    # grounded facts (the planner picks pair-polymath bash code instead
    # of the fixture's intended file). Found while establishing the
    # post-Phase-2.1 baseline: all 7 lenses returned malformed output
    # because the grounded context was confused by the host's files.
    cwd_state_dir="$sandbox/cwd"
    cp -r "$fix_dir/cwd-state" "$cwd_state_dir"
    (cd "$cwd_state_dir" && \
       git init -q 2>/dev/null && \
       git add -A 2>/dev/null && \
       git -c user.email=fixture@local -c user.name=fixture commit -q -m "fixture state" 2>/dev/null) || true
  elif [ -f "$fix_dir/cwd-state.txt" ]; then
    # Legacy single-file fixture support. Same isolation pattern: copy to
    # sandbox + git init so cwd doesn't inherit the host's git tree.
    cwd_state_dir="$sandbox/cwd"
    mkdir -p "$cwd_state_dir"
    cp "$fix_dir/cwd-state.txt" "$cwd_state_dir/"
    (cd "$cwd_state_dir" && \
       git init -q 2>/dev/null && \
       git add -A 2>/dev/null && \
       git -c user.email=fixture@local -c user.name=fixture commit -q -m "fixture state" 2>/dev/null) || true
  fi

  # Rewrite @TRANSCRIPT@ / @CWD@ placeholders. R1 code-reviewer H2 + GPT
  # HIGH: previous sed-based approach interpolated paths INTO the sed
  # program body, so a path containing |, &, or \n would corrupt the sed
  # script (`s|@TRANSCRIPT@|/tmp/p|p-eval-foo|g` — broken delimiter on the
  # second `|`). Use jq's string-replace on the parsed JSON instead: paths
  # become safe arguments via --arg, not interpolated into a script body.
  if [ -n "$cwd_state_dir" ]; then
    jq --arg t "$transcript" --arg c "$cwd_state_dir" '
      walk(if type == "string" then
        gsub("@TRANSCRIPT@"; $t) | gsub("@CWD@"; $c)
      else . end)
    ' "$input_json" > "$input_resolved" 2>/dev/null || {
      printf 'run-eval.sh: failed to rewrite placeholders in %s\n' "$input_json" >&2
      return 1
    }
  else
    jq --arg t "$transcript" '
      walk(if type == "string" then gsub("@TRANSCRIPT@"; $t) else . end)
    ' "$input_json" > "$input_resolved" 2>/dev/null || {
      printf 'run-eval.sh: failed to rewrite placeholders in %s\n' "$input_json" >&2
      return 1
    }
  fi

  # Build a synthetic session_id from the fixture name so cache paths are
  # predictable (bin/statusline.sh sanitizes anyway, but we want determinism).
  fix_session="fixture-$(printf '%s' "$fix" | tr -cd 'a-zA-Z0-9._-')"
  # Splice session_id into the resolved input.json. R1 code-reviewer M2:
  # `|| cat` fallback hid jq failures and could leave session_id unset →
  # cache collisions across fixtures. If jq fails here something is
  # actually broken; fail loud instead.
  if ! jq --arg sid "$fix_session" '.session_id = $sid' "$input_resolved" > "${input_resolved}.tmp" 2>/dev/null; then
    printf 'run-eval.sh: failed to set session_id in %s\n' "$input_resolved" >&2
    rm -f "${input_resolved}.tmp"
    return 1
  fi
  mv "${input_resolved}.tmp" "$input_resolved"

  obs_file="$run_dir/${fix}.observations.txt"
  err_file="$run_dir/${fix}.stderr.txt"

  # Env for this fixture's invocation. PP_PARALLEL_INTERVAL_S=1 forces the
  # cycle gate open even in normal mode. PP_IDLE_THRESHOLD_S high so the
  # synthetic transcript's mtime is never seen as idle. PP_EXTERNAL_LLM=0
  # for --dry-run skips all LLM calls.
  external_llm=1
  [ "$dry_run" = "1" ] && external_llm=0

  # lib/config.sh loads config/default.env before user.env, so process-env
  # overrides alone are not enough for eval controls whose defaults are set
  # there (notably PP_EXTERNAL_LLM). Write the fixture's overrides into the
  # sandboxed user config so dry-run is genuinely zero-LLM and trace capture
  # is consistently enabled for non-dry eval cycles.
  eval_config_dir="$sandbox/.claude/pair-polymath/config"
  mkdir -p "$eval_config_dir"
  {
    printf 'PP_EVAL_MODE=1\n'
    printf 'PP_EVAL_ROUTER_SHADOW=1\n'
    printf 'PP_TRACE_ENABLE=1\n'
    printf 'PP_EXTERNAL_LLM=%s\n' "$external_llm"
    printf 'PP_PARALLEL_INTERVAL_S=1\n'
    printf 'PP_IDLE_THRESHOLD_S=999999\n'
  } > "$eval_config_dir/user.env"
  chmod 600 "$eval_config_dir/user.env" 2>/dev/null || true

  # Preserve llm's config path so the sandbox HOME doesn't break key
  # resolution. Without LLM_USER_PATH, llm under the sandboxed HOME finds
  # no keys.json and either fails with 429 'insufficient_quota' from an
  # anonymous/fallback path OR returns empty silently. Metrics still
  # increment (statusline counts before the call) but every analyst's
  # lens_suggestion comes back empty → 0 observations. Discovered during
  # post-Phase-2.1 baseline establishment when 7/7 analysts came back
  # blank despite the cycle being billed.
  llm_config_dir=""
  case "$(uname -s 2>/dev/null)" in
    Darwin) llm_config_dir="$HOME/Library/Application Support/io.datasette.llm" ;;
    Linux)  llm_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/io.datasette.llm" ;;
    *)      llm_config_dir="$HOME/.config/io.datasette.llm" ;;
  esac

  set +e
  HOME="$sandbox" \
    CLAUDE_DIR="$sandbox/.claude" \
    PP_CACHE_DIR="$sandbox/.claude/cache" \
    PP_STATE_DIR="$sandbox/.claude/pair-polymath" \
    PP_EVAL_MODE=1 \
    PP_TRACE_ENABLE=1 \
    PP_EXTERNAL_LLM="$external_llm" \
    PP_PARALLEL_INTERVAL_S=1 \
    PP_IDLE_THRESHOLD_S=999999 \
    LLM_USER_PATH="$llm_config_dir" \
    bash "$_statusline" < "$input_resolved" > "$obs_file" 2> "$err_file"
  rc=$?
  set -e

  # Count "real" observations (non-blank body) for the summary.
  fix_obs=0
  if [ -s "$obs_file" ]; then
    # A populated obs row has 4 non-empty fields. The dry-run/empty rows have
    # 3 trailing empty fields (only lens id present).
    fix_obs=$(awk -F'\\|\\|\\|' 'NF>=4 && length($4)>0 {n++} END{print n+0}' "$obs_file")
  fi

  # Preserve bounded trace rows before deleting the sandbox. Per-fixture files
  # keep the raw emitted rows; trace.jsonl adds fixture=<name> so reports can
  # aggregate across a whole run without opening every sandbox artifact.
  fix_trace_rows=0
  trace_tag_err=0
  trace_src="$sandbox/.claude/cache/trace-cycle.jsonl"
  if [ -s "$trace_src" ]; then
    fix_trace_file="$run_dir/${fix}.trace.jsonl"
    cp "$trace_src" "$fix_trace_file"
    fix_trace_rows=$(awk 'END{print NR + 0}' "$trace_src")
    if ! jq -c --arg fixture "$fix" '. + {fixture: $fixture}' "$trace_src" >> "$run_dir/trace.jsonl" 2>/dev/null; then
      printf 'run-eval.sh: failed to tag trace rows for %s\n' "$fix" >&2
      trace_tag_err=1
    fi
  fi

  # Error count = nonzero exit OR stderr non-empty. Keep it simple — the JSON
  # summary records both signals indirectly via errors_per_fixture.
  fix_err=0
  [ "$rc" -ne 0 ] && fix_err=1
  [ -s "$err_file" ] && fix_err=$((fix_err + 1))
  [ "$trace_tag_err" -ne 0 ] && fix_err=$((fix_err + 1))

  if [ "$errors_first" = "1" ]; then
    errors_first=0
  else
    errors_json="${errors_json},"
  fi
  errors_json="${errors_json}\"$fix\": $fix_err"

  if [ "$trace_rows_first" = "1" ]; then
    trace_rows_first=0
  else
    trace_rows_json="${trace_rows_json},"
  fi
  trace_rows_json="${trace_rows_json}\"$fix\": $fix_trace_rows"

  fixtures_processed=$((fixtures_processed + 1))
  total_observations=$((total_observations + fix_obs))
  total_trace_rows=$((total_trace_rows + fix_trace_rows))

  # Clean the sandbox, leave only run-dir artifacts.
  rm -rf "$sandbox"
done

errors_json="${errors_json}}"
trace_rows_json="${trace_rows_json}}"

# Atomic write of the run summary. tmp+mv discipline (PR #19/#25 lesson).
summary_path="$run_dir/run-summary.json"
summary_tmp="${summary_path}.tmp.$$"
cat > "$summary_tmp" <<EOF
{
  "run_ts": "$run_ts",
  "fixtures_processed": $fixtures_processed,
  "errors_per_fixture": $errors_json,
  "trace_rows_per_fixture": $trace_rows_json,
  "total_observations": $total_observations,
  "total_trace_rows": $total_trace_rows,
  "dry_run": $dry_run
}
EOF
mv "$summary_tmp" "$summary_path"

# Also stamp the latest run dir for convenience (so score.sh --latest works).
latest_link="$_runs_dir/latest"
printf '%s\n' "$run_ts" > "${latest_link}.tmp.$$" && mv "${latest_link}.tmp.$$" "$latest_link"

printf 'run-eval.sh: %d fixture(s) processed → %s\n' "$fixtures_processed" "$run_dir"
printf 'run-eval.sh: total observations: %d\n' "$total_observations"
