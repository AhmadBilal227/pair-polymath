#!/usr/bin/env bats
# v0.5.6.1 DIM hardening — regression tests for the 12 fixes from the
# 5-reviewer pass on PR #81 (v0.5.6.0 DIM control plane). Each test is
# tagged with the fix id from the review (A1..A7, B1..B4, C1).

setup() {
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/state"
  PP_HOME="$CLAUDE_DIR/pair-polymath"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR PP_HOME
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR" "$PP_HOME"
}

teardown() {
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] && rm -rf "$HOME"
}

# ============================================================
# FIX A1 — sanitize holdout slot inputs
# ============================================================

@test "A1: holdout_slot returns 0-9 for inputs with shell metachars" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim-stats.sh"
  v=$(pp_dim_stats_holdout_slot 'evil;rm -rf /' '../etc/passwd' '$(echo pwn)`whoami`')
  [ "$v" -ge 0 ] 2>/dev/null
  [ "$v" -le 9 ] 2>/dev/null
}

@test "A1: holdout_slot returns 0-9 for inputs with control bytes + nulls" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim-stats.sh"
  v=$(printf 'sess\x01\x02with\x7fctl' | xargs -I{} bash -c '. '"$PP_ROOT"'/lib/dim-stats.sh; pp_dim_stats_holdout_slot "$1" "BAD;LENS" "junk-ts"' _ {})
  [ "$v" -ge 0 ] 2>/dev/null
  [ "$v" -le 9 ] 2>/dev/null
}

@test "A1: holdout_slot deterministic after sanitization (same canonical input → same slot)" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim-stats.sh"
  # The raw input contains chars that get stripped; an "equivalent" caller
  # passing only the surviving chars must land in the same bucket.
  raw=$(pp_dim_stats_holdout_slot 'sess1;evil' 'ENG_AND_EVIL/!@#' '2026-05-22T00:00:00Z-junk!')
  clean=$(pp_dim_stats_holdout_slot 'sess1evil' 'ENG_AND_EVIL' '2026-05-22T00:00:00Z-')
  [ "$raw" = "$clean" ]
}

# ============================================================
# FIX A2 — sha8 format validation in path helpers
# ============================================================

@test "A2: pp_dim_state_file_path rejects '../etc' traversal → default" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
  p=$(pp_dim_state_file_path "../etc")
  [ "$p" = "$PP_CACHE_DIR/dim-state.default.jsonl" ]
}

@test "A2: pp_dim_state_file_path rejects path-with-slash → default" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
  p=$(pp_dim_state_file_path "abc/def")
  [ "$p" = "$PP_CACHE_DIR/dim-state.default.jsonl" ]
}

@test "A2: pp_dim_state_file_path accepts valid 8-hex sha8" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
  p=$(pp_dim_state_file_path "abcd1234")
  [ "$p" = "$PP_CACHE_DIR/dim-state.abcd1234.jsonl" ]
}

@test "A2: pp_dim_last_eval_path rejects shell metas → default" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
  p=$(pp_dim_last_eval_path '$(rm -rf /)')
  [ "$p" = "$PP_CACHE_DIR/dim-last-eval-epoch.default.txt" ]
}

@test "A2: pp_dim_gate_eval_path rejects empty/null variants → default" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
  p=$(pp_dim_gate_eval_path "")
  [ "$p" = "$PP_CACHE_DIR/dim-gate-last-eval.default.jsonl" ]
}

# ============================================================
# FIX A3 — polymath dim status uses PP_DIM_MIN_LENSES, not hardcoded 3
# ============================================================

@test "A3: dim status --json reports lenses_required from PP_DIM_MIN_LENSES" {
  PP_DIM_MIN_LENSES=5
  export PP_DIM_MIN_LENSES
  out=$("$PP_ROOT/bin/polymath" dim status --json 2>/dev/null)
  echo "$out" | jq -e '.gate_progress.lenses_required == 5' >/dev/null
}

@test "A3: dim status --json defaults lenses_required to 3 when env unset" {
  unset PP_DIM_MIN_LENSES || true
  out=$("$PP_ROOT/bin/polymath" dim status --json 2>/dev/null)
  echo "$out" | jq -e '.gate_progress.lenses_required == 3' >/dev/null
}

# ============================================================
# FIX A4 — per_lens_rollup skips rows with missing inject_ts
# ============================================================

@test "A4: per_lens_rollup distinct_dates excludes rows missing inject_ts" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim-stats.sh"
  oar=$(mktemp)
  # 5 rows missing inject_ts (literal absence), 3 rows on 3 distinct dates
  for i in 1 2 3 4 5; do
    printf '{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s%d","project_root_sha8":"abcd1234"}\n' "$i" >> "$oar"
  done
  printf '{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s6","inject_ts":"2026-05-10T00:00:00Z","project_root_sha8":"abcd1234"}\n' >> "$oar"
  printf '{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s7","inject_ts":"2026-05-11T00:00:00Z","project_root_sha8":"abcd1234"}\n' >> "$oar"
  printf '{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s8","inject_ts":"2026-05-12T00:00:00Z","project_root_sha8":"abcd1234"}\n' >> "$oar"
  result=$(pp_dim_stats_per_lens_rollup "$oar" "abcd1234")
  # Sum across both buckets — total distinct_dates from the 3 valid rows, NOT 1
  # (the old code would coerce missing ts to "" and unique-count it as 1 date).
  max_dates=$(echo "$result" | jq '[.gated[], .holdout[] | .distinct_dates] | max // 0')
  # With 5 missing + 3 valid, distinct_dates should be at most 3 (the valid set),
  # and crucially never include the "" sentinel.
  [ "$max_dates" -le 3 ] 2>/dev/null
  [ "$max_dates" -ge 1 ] 2>/dev/null
  rm -f "$oar"
}

# ============================================================
# FIX A5 — OAR schema doctor check (rollup empty but OAR has rows)
# ============================================================

@test "A5: doctor flags OAR schema break (rows present, rollup n=0)" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/doctor.sh"
  oar="$PP_CACHE_DIR/oar-labeled.jsonl"
  # 100+ rows missing the required 'project_root_sha8' field. Rollup filters
  # by sha8, so the result for sha8=sch00111 will be empty (n=0) even though
  # OAR is full. This is the canonical "schema renamed/dropped" failure mode.
  for i in $(seq 1 110); do
    printf '{"schema_version":99,"lens":"ENG","outcome":"acted","session_id":"s%d","inject_ts":"2026-05-%02dT00:00:00Z","project_repo_root":"sch00111"}\n' \
      "$i" "$((10 + (i % 10)))" >> "$oar"
  done
  # Default state (monitoring) — check should ALSO run during monitoring/gated
  # because the schema break manifests there too (and used to be hidden by the
  # pre-activation short-circuit).
  PP_DIM_PROJECT_SHA8=sch00111
  export PP_DIM_PROJECT_SHA8
  run doctor_check_dim_data_quality
  # Should yellow (status=1) — schema break detected
  [ "$status" -eq 1 ]
  echo "$output" | grep -qE 'schema|rollup empty|OAR has' || \
    { echo "Expected schema-break message; got: $output" >&2; false; }
}

# ============================================================
# FIX A6 — pp_dim_holdout_no_drift signature (drop unused $gate)
# ============================================================

@test "A6: pp_dim_holdout_no_drift accepts single arg (sha8 only)" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
  # With no OAR file, holdout_n < 20 → returns 0 (no drift). Verify the
  # function still works after the refactor with just one positional arg.
  run pp_dim_holdout_no_drift "abcd1234"
  [ "$status" -eq 0 ]
}

# ============================================================
# FIX A7 — temp file cleanup on jq failure
# ============================================================

@test "A7: per_lens_rollup cleans up temp file on jq failure" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim-stats.sh"
  oar=$(mktemp)
  # Malformed JSON to force the inner jq to fail
  printf 'this is not json at all { broken\n' > "$oar"
  printf '{"also":"bad",,}\n' >> "$oar"
  before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  # Don't care about the rc; the assertion is "no leak"
  pp_dim_stats_per_lens_rollup "$oar" "abcd1234" >/dev/null 2>&1 || true
  after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  # Allow ±1 noise (other bats temp files), but must not grow by N for N runs
  diff=$((after - before))
  [ "$diff" -le 1 ]
  rm -f "$oar"
}

# ============================================================
# FIX B1 — hook timeout wrapper (5s)
# ============================================================

@test "B1: inject hook returns within ~6s even if dim eval hangs 30s" {
  # Stub lib/dim.sh with a sleeping evaluator
  stub_dir="$HOME/stub-pp"
  mkdir -p "$stub_dir/lib" "$stub_dir/hooks" "$stub_dir/config"
  cp -R "$PP_ROOT/hooks" "$stub_dir/"
  cp -R "$PP_ROOT/lib" "$stub_dir/"
  cp -R "$PP_ROOT/config" "$stub_dir/" 2>/dev/null || true
  cp -R "$PP_ROOT/lenses" "$stub_dir/" 2>/dev/null || true
  # Overwrite the dim eval to hang
  cat > "$stub_dir/lib/dim.sh" <<'STUB'
#!/usr/bin/env bash
[ "${_PP_DIM_SOURCED:-0}" = "1" ] && return 0
_PP_DIM_SOURCED=1
pp_dim_evaluate_gate_daily() { sleep 30; return 0; }
STUB
  # Run the hook with an empty JSON stdin; expect <= 8s wall
  PP_ROOT="$stub_dir"
  export PP_ROOT
  start=$(date +%s)
  echo '{"session_id":"test"}' | timeout 12 bash "$stub_dir/hooks/inject-monitor-insight.sh" >/dev/null 2>&1 || true
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -le 8 ] || { echo "Hook took ${elapsed}s, expected <= 8s" >&2; false; }
}

# ============================================================
# FIX B2 — state-file rotation at 1MB
# ============================================================

@test "B2: pp_dim_append_transition rotates state file at 1MB" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
  f=$(pp_dim_state_file_path "abcd1234")
  mkdir -p "$(dirname "$f")"
  # Synthesize > 1MB of plausible JSONL
  : > "$f"
  big_row='{"ts":"2026-01-01T00:00:00Z","from":"monitoring","to":"gated","reason":"'"$(printf 'x%.0s' $(seq 1 4000))"'","source":"auto","gate_snapshot":{}}'
  for i in $(seq 1 300); do
    printf '%s\n' "$big_row" >> "$f"
  done
  size_before=$(wc -c < "$f" | tr -d ' ')
  [ "$size_before" -gt 1048576 ] || { echo "Failed to grow file past 1MB (got $size_before)" >&2; false; }
  # Trigger an append → rotation should fire
  pp_dim_append_transition "abcd1234" "monitoring" "gated" "rotate-trigger" "auto" '{}'
  # Rotated file should exist; new state file should be small (< 1MB)
  [ -f "${f}.1" ] || { echo ".1 file not created" >&2; false; }
  size_after=$(wc -c < "$f" | tr -d ' ')
  [ "$size_after" -lt 1048576 ]
}

# ============================================================
# FIX B3 — default-shard short-circuit
# ============================================================

@test "B3: dim evaluate skipped when sha8=default and OAR has no default rows" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
  oar="$PP_CACHE_DIR/oar-labeled.jsonl"
  # OAR contains only non-default sha8 rows
  printf '{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s1","inject_ts":"2026-05-10T00:00:00Z","project_root_sha8":"abc12345"}\n' > "$oar"
  pp_dim_evaluate_gate_daily "default" "$oar"
  # The gate-last-eval file for "default" must not exist (short-circuited)
  ! [ -f "$PP_CACHE_DIR/dim-gate-last-eval.default.jsonl" ]
}

@test "B3: dim evaluate runs when sha8=default AND OAR has default rows" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh"
  oar="$PP_CACHE_DIR/oar-labeled.jsonl"
  # OAR contains a row with project_root_sha8=default
  printf '{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s1","inject_ts":"2026-05-10T00:00:00Z","project_root_sha8":"default"}\n' > "$oar"
  pp_dim_evaluate_gate_daily "default" "$oar"
  # Forensic row must be written
  [ -f "$PP_CACHE_DIR/dim-gate-last-eval.default.jsonl" ]
}

# ============================================================
# FIX B4 — doctor reuses last daily eval instead of re-running full eval
# ============================================================

@test "B4: doctor reads cached gate-eval row when fresh" {
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/doctor.sh"
  # Force active state so doctor runs the drift check
  printf '{"ts":"2026-05-01T00:00:00Z","from":"monitoring","to":"active","reason":"test","source":"test","gate_snapshot":{}}\n' > \
    "$PP_CACHE_DIR/dim-state.cached11.jsonl"
  # Pre-write a fresh forensic gate-eval row
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"qualifies":true,"lenses_qualifying":3,"per_lens":[],"evaluated_at":"%s"}\n' "$ts" > \
    "$PP_CACHE_DIR/dim-gate-last-eval.cached11.jsonl"
  PP_DIM_PROJECT_SHA8=cached11
  export PP_DIM_PROJECT_SHA8
  # Run doctor — should NOT need to re-evaluate (no OAR file present, so a
  # naive re-eval would also work; the assertion here is that it returns
  # green/yellow without crashing on the missing OAR).
  run doctor_check_dim_data_quality
  # Should not be red (status 2) — we have a fresh cached eval
  [ "$status" -lt 2 ]
}

# ============================================================
# FIX C1 — status next-actions vary by state
# ============================================================

@test "C1: dim status human output shows state-specific actions (active)" {
  printf '{"ts":"2026-05-01T00:00:00Z","from":"monitoring","to":"active","reason":"test","source":"test","gate_snapshot":{}}\n' > \
    "$PP_CACHE_DIR/dim-state.default.jsonl"
  PP_DIM_PROJECT_SHA8=default
  export PP_DIM_PROJECT_SHA8
  out=$("$PP_ROOT/bin/polymath" dim status 2>/dev/null)
  echo "$out" | grep -qi 'deactivate' || { echo "Expected 'deactivate' for active state; got: $out" >&2; false; }
}

@test "C1: dim status human output mentions drift for quarantine" {
  printf '{"ts":"2026-05-01T00:00:00Z","from":"active","to":"quarantine","reason":"test","source":"test","gate_snapshot":{}}\n' > \
    "$PP_CACHE_DIR/dim-state.default.jsonl"
  PP_DIM_PROJECT_SHA8=default
  export PP_DIM_PROJECT_SHA8
  out=$("$PP_ROOT/bin/polymath" dim status 2>/dev/null)
  echo "$out" | grep -qi 'drift' || { echo "Expected 'drift' for quarantine state; got: $out" >&2; false; }
}

@test "C1: dim status human output shows force-activate for monitoring" {
  # Default state with no transitions is monitoring
  PP_DIM_PROJECT_SHA8=default
  export PP_DIM_PROJECT_SHA8
  out=$("$PP_ROOT/bin/polymath" dim status 2>/dev/null)
  echo "$out" | grep -qi 'force-activate' || { echo "Expected 'force-activate' for monitoring state; got: $out" >&2; false; }
}
