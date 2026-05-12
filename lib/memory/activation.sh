#!/usr/bin/env bash
# Pair Polymath — ACT-R-inspired activation scoring.
#
# This is a HEURISTIC inspired by ACT-R base-level activation, not the
# full formula. ACT-R proper uses sum_j t_j^-d over multiple presentations
# plus spreading activation from working memory. We use a simpler additive
# form because we have per-row use_count + last_seen_ts only:
#
#   activation = ln(use_count + 1)
#              - decay_per_day × days_since_last_seen
#              + 0.6 × act_count
#              + 0.4 × signal_retention
#
# Multipliers (0.6, 0.4) and decay default (0.5/day) were chosen so a fresh
# observation (use_count=1, days=0) scores ≈ 0.693 (ln 2), and one week
# of inactivity with no further use brings it down to ≈ -2.81 — i.e. fades
# below practically any newer entry. Tunable via PP_MEMORY_DECAY_PER_DAY.
#
# ─── Signal consumption (F9) ──────────────────────────────────────────────
# Only signal_retention is read by this scorer (the +0.4 term above).
# signal_retention is GRADED (cumulative bumps; see lib/memory/signals.sh).
#
# The remaining 3 signals on the observations table are BINARY one-shots
# reserved for Task D weight-sweep:
#   - signal_file_edit
#   - signal_commit_mention
#   - signal_test_flip
# Touching their weights in this formula without first running the weight
# sweep will change retrieval ordering on every existing row, so leave
# them as columns-only until Task D selects multipliers.

if [ -z "${PP_ROOT:-}" ]; then
  _pp_memory_activation_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
  PP_ROOT="$_pp_memory_activation_dir"
  unset _pp_memory_activation_dir
fi
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/schema.sh"

# _pp_memory_activation_is_number VALUE
# Numeric regex guard. Same shape as _pp_memory_is_number in store.sh but
# duplicated here so activation.sh is sourceable without store.sh loaded.
_pp_memory_activation_is_number() {
  local val="$1"
  case "$val" in
    ''|*[!0-9.-]*) return 1 ;;
  esac
  printf '%s' "$val" | LC_ALL=C grep -qE '^-?[0-9]+(\.[0-9]+)?$'
}

# pp_memory_activation_score USE_COUNT DAYS_OLD ACT_COUNT RETENTION [DECAY_PER_DAY]
# Stdout: the activation score to 4 decimal places. awk handles the math so
# we stay portable (no bc dependency, no $(()) float ops which bash lacks).
# All 5 args are validated as numeric even though current callers are
# internal — defense-in-depth in case future callers pass user input.
pp_memory_activation_score() {
  local use_count="${1:-0}" days_old="${2:-0}"
  local act_count="${3:-0}" retention="${4:-0}"
  local decay="${5:-0.5}"
  local arg
  for arg in "$use_count" "$days_old" "$act_count" "$retention" "$decay"; do
    if ! _pp_memory_activation_is_number "$arg"; then
      printf 'pp_memory_activation_score: non-numeric arg %s\n' "$arg" >&2
      return 1
    fi
  done
  LC_ALL=C awk -v u="$use_count" -v d="$days_old" \
      -v a="$act_count" -v r="$retention" -v k="$decay" '
    BEGIN { printf "%.4f", log(u + 1) - k * d + 0.6 * a + 0.4 * r }
  '
}

# pp_memory_recompute_scores CWD
# Recomputes activation_score for EVERY row in this project's DB using SQL
# (one statement, atomic). julianday() gives portable fractional-day math.
# MUST be called under pp_memory_with_lock — this is a read-modify-write
# across all rows, and concurrent writers would race on intermediate values.
pp_memory_recompute_scores() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  # Lock contract enforcement. This function does a full-table RMW; concurrent
  # writers would race on intermediate values. Caller MUST wrap us in
  # pp_memory_with_lock, which creates .maint.lock as a directory.
  if [ ! -d "$proj_dir/.maint.lock" ]; then
    printf 'pp_memory_recompute_scores: must be called under pp_memory_with_lock\n' >&2
    return 1
  fi
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0
  local decay="${PP_MEMORY_DECAY_PER_DAY:-0.5}"
  # Numeric validation — decay is interpolated as a bare SQL literal, so any
  # non-numeric string is a SQL injection vector.
  if ! _pp_memory_activation_is_number "$decay"; then
    printf 'pp_memory_recompute_scores: invalid decay=%s\n' "$decay" >&2
    return 1
  fi
  # Also require non-negative.
  if LC_ALL=C awk -v v="$decay" 'BEGIN { exit (v+0 >= 0 ? 1 : 0) }'; then
    printf 'pp_memory_recompute_scores: decay=%s must be >= 0\n' "$decay" >&2
    return 1
  fi
  # julianday(last_seen_ts) returns NULL on malformed timestamps, which would
  # poison activation_score to NULL forever. COALESCE chain: prefer
  # last_seen_ts, fall back to ts (NOT NULL per schema), final fallback to
  # 'now' so a fully-corrupt row at least scores deterministically instead of
  # ranking bottom forever.
  # R3.1: sqlite3's `log()` is base-10 on macOS 3.43 + Ubuntu 3.45 (verified
  # empirically against `SELECT log(2.718281828)` returning 0.434, not 1.0).
  # Spec wants natural log to match the shell awk formula in
  # pp_memory_activation_score (line 69). Use `ln()` explicitly — both target
  # builds support it as natural log. If a future build lacks `ln()`, the
  # statement errors loudly (we'd rather see that than silently score wrong).
  pp_memory_sqlite "$db" <<SQL
UPDATE observations
SET activation_score =
  ln(COALESCE(use_count, 0) + 1)
  - $decay * (julianday('now') - COALESCE(julianday(last_seen_ts), julianday(ts), julianday('now')))
  + 0.6 * COALESCE(act_count, 0)
  + 0.4 * COALESCE(signal_retention, 0);
SQL
}
