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

if [ -z "${PP_ROOT:-}" ]; then
  _pp_memory_activation_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
  PP_ROOT="$_pp_memory_activation_dir"
  unset _pp_memory_activation_dir
fi
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/schema.sh"

# pp_memory_activation_score USE_COUNT DAYS_OLD ACT_COUNT RETENTION [DECAY_PER_DAY]
# Stdout: the activation score to 4 decimal places. awk handles the math so
# we stay portable (no bc dependency, no $(()) float ops which bash lacks).
pp_memory_activation_score() {
  local use_count="${1:-0}" days_old="${2:-0}"
  local act_count="${3:-0}" retention="${4:-0}"
  local decay="${5:-0.5}"
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
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0
  local decay="${PP_MEMORY_DECAY_PER_DAY:-0.5}"
  pp_memory_sqlite "$db" <<SQL
UPDATE observations
SET activation_score =
  log(COALESCE(use_count, 0) + 1)
  - $decay * (julianday('now') - julianday(last_seen_ts))
  + 0.6 * COALESCE(act_count, 0)
  + 0.4 * COALESCE(signal_retention, 0);
SQL
}
