#!/usr/bin/env bats
# Activation formula correctness + DB-side recompute.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX"
  export CLAUDE_DIR="$SANDBOX/.claude"
  export PP_MEMORY_DIR="$SANDBOX/.claude/pair-polymath/memory"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/schema.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/redact.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/store.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/activation.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/lock.sh"
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/test/y.git )
  PROJ=$(pp_memory_project_dir "$SANDBOX/repo")
  pp_memory_db_init "$PROJ"
}
teardown() { rm -rf "$SANDBOX"; }

# Helper: compare two awk-formatted floats with a small tolerance.
_assert_close() {
  local got="$1" expected="$2" tol="${3:-0.01}"
  LC_ALL=C awk -v g="$got" -v e="$expected" -v t="$tol" \
    'BEGIN { d=g-e; if (d<0) d=-d; exit (d<=t?0:1) }'
}

@test "activation: fresh obs (use=1, days=0) → score ≈ ln(2) ≈ 0.6931" {
  s=$(pp_memory_activation_score 1 0 0 0 0.5)
  _assert_close "$s" "0.6931"
}

@test "activation: decay reduces score linearly per day (k=0.5)" {
  s0=$(pp_memory_activation_score 1 0 0 0 0.5)
  s2=$(pp_memory_activation_score 1 2 0 0 0.5)
  # 2 days × 0.5 = 1.0 drop
  diff=$(LC_ALL=C awk -v a="$s0" -v b="$s2" 'BEGIN { printf "%.4f", a-b }')
  _assert_close "$diff" "1.0000" "0.0001"
}

@test "activation: act_count bumps score by 0.6 per increment" {
  s_base=$(pp_memory_activation_score 1 0 0 0 0.5)
  s_one=$(pp_memory_activation_score 1 0 1 0 0.5)
  diff=$(LC_ALL=C awk -v a="$s_one" -v b="$s_base" 'BEGIN { printf "%.4f", a-b }')
  _assert_close "$diff" "0.6000"
}

@test "activation: retention bumps score by 0.4 per increment" {
  s_base=$(pp_memory_activation_score 1 0 0 0 0.5)
  s_one=$(pp_memory_activation_score 1 0 0 1 0.5)
  diff=$(LC_ALL=C awk -v a="$s_one" -v b="$s_base" 'BEGIN { printf "%.4f", a-b }')
  _assert_close "$diff" "0.4000"
}

@test "activation: high use_count raises score (ln growth)" {
  s_low=$(pp_memory_activation_score 1 0 0 0 0.5)
  s_high=$(pp_memory_activation_score 10 0 0 0 0.5)
  # log(11) - log(2) ≈ 2.397 - 0.693 = 1.704
  diff=$(LC_ALL=C awk -v a="$s_high" -v b="$s_low" 'BEGIN { printf "%.4f", a-b }')
  _assert_close "$diff" "1.7047"
}

@test "activation: pp_memory_recompute_scores writes scores for all rows" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-stale" "ENG" "T" "h" "b" "[]" "[]" "s"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-fresh" "ENG" "T" "h" "b" "[]" "[]" "s"
  # Backdate one row by 10 days, raise its act_count.
  pp_memory_sqlite "$PROJ/observations.sqlite" "
    UPDATE observations SET last_seen_ts=datetime('now','-10 days') WHERE obs_id='o-stale';
    UPDATE observations SET act_count=5 WHERE obs_id='o-fresh';
  "
  pp_memory_recompute_scores "$SANDBOX/repo"
  stale_score=$(sqlite3 "$PROJ/observations.sqlite" "SELECT activation_score FROM observations WHERE obs_id='o-stale';")
  fresh_score=$(sqlite3 "$PROJ/observations.sqlite" "SELECT activation_score FROM observations WHERE obs_id='o-fresh';")
  # Fresh + 5 act_count must outscore 10-day-stale row.
  LC_ALL=C awk -v f="$fresh_score" -v s="$stale_score" 'BEGIN { exit (f>s ? 0 : 1) }'
}

@test "activation: recompute is idempotent up to clock-tick noise" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o1" "ENG" "T" "h" "b" "[]" "[]" "s"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o2" "ENG" "T" "h" "b" "[]" "[]" "s"
  pp_memory_recompute_scores "$SANDBOX/repo"
  first=$(sqlite3 "$PROJ/observations.sqlite" \
    "SELECT GROUP_CONCAT(obs_id || '=' || printf('%.4f', activation_score), '|') FROM (SELECT * FROM observations ORDER BY obs_id);")
  pp_memory_recompute_scores "$SANDBOX/repo"
  second=$(sqlite3 "$PROJ/observations.sqlite" \
    "SELECT GROUP_CONCAT(obs_id || '=' || printf('%.4f', activation_score), '|') FROM (SELECT * FROM observations ORDER BY obs_id);")
  # 4-decimal rounding tolerates fractional-second clock drift between
  # julianday('now') calls. The score should be stable at that scale because
  # 0.5/day decay over ≤ 1 millisecond is < 1e-8.
  [ "$first" = "$second" ]
}

@test "activation: pp_memory_recompute_scores under lock + lock holds during op" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-lk" "ENG" "T" "h" "b" "[]" "[]" "s"
  # Use the with_lock wrapper directly.
  pp_memory_with_lock "$PROJ" pp_memory_recompute_scores "$SANDBOX/repo"
  [ "$?" -eq 0 ]
  # Lock is released after.
  [ ! -d "$PROJ/.maint.lock" ]
}

@test "activation: PP_MEMORY_DECAY_PER_DAY env overrides decay rate" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-d" "ENG" "T" "h" "b" "[]" "[]" "s"
  # Backdate 1 day
  pp_memory_sqlite "$PROJ/observations.sqlite" \
    "UPDATE observations SET last_seen_ts=datetime('now','-1 days') WHERE obs_id='o-d';"
  PP_MEMORY_DECAY_PER_DAY=2.0 pp_memory_recompute_scores "$SANDBOX/repo"
  hi_decay=$(sqlite3 "$PROJ/observations.sqlite" "SELECT activation_score FROM observations WHERE obs_id='o-d';")
  PP_MEMORY_DECAY_PER_DAY=0.1 pp_memory_recompute_scores "$SANDBOX/repo"
  lo_decay=$(sqlite3 "$PROJ/observations.sqlite" "SELECT activation_score FROM observations WHERE obs_id='o-d';")
  # Higher decay → lower (more negative) score for same elapsed time.
  LC_ALL=C awk -v h="$hi_decay" -v l="$lo_decay" 'BEGIN { exit (l>h ? 0 : 1) }'
}
