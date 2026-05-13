#!/usr/bin/env bash
# Pair Polymath — budget tracking. Atomic via a SINGLE shared mkdir lock.
# Sourced by bin/statusline.sh. Requires PP_CACHE_DIR + PP_MAX_DAILY_CALLS in env.
#
# All mutations of the budget file serialize through one lock. The prior
# split-lock design (.inc.lock vs .reserve.lock) allowed inc and reserve to
# race on the same file and lose updates.

# v0.4.3 single-source default for the daily cap. Was scattered across three
# call sites (lib/budget.sh:53 :-3500, lib/budget.sh:76 :-10000, bin/polymath
# :-3500) — when PP_MAX_DAILY_CALLS was unset, the status pretty-print and
# budget-pressure pip disagreed about the cap. `:=` sets and exports the
# default exactly once, on source.
: "${PP_MAX_DAILY_CALLS:=10000}"

# v0.4.3 midnight-rollover fix. The prior `PP_BUDGET_FILE=...$(date +%Y%m%d)...`
# was evaluated at source-time only. bin/statusline.sh refreshes every 2s for
# days; after midnight, increments kept writing to yesterday's file → today's
# budget pressure read 0/cap → cycles fired thinking they had headroom that
# was actually exhausted under the wrong key. polymath caught its own bug via
# a lens-self-observation and surfaced it to the maintainer in the advisory
# rotation. Fix: re-evaluate the path on every call via pp_budget_file_path.
#
# The lock path is intentionally DATE-INDEPENDENT (just $PP_CACHE_DIR/
# pp-budget.lock) so writers on either side of midnight serialize through one
# lock instead of grabbing per-day locks and racing on the new-day file.
pp_budget_file_path() {
  printf '%s/pp-budget-%s.txt' "$PP_CACHE_DIR" "$(date +%Y%m%d)"
}

pp_budget_lock_path() {
  printf '%s/pp-budget.lock' "$PP_CACHE_DIR"
}

# Source-time snapshot kept for back-compat with test/budget.bats and any
# external code that has historically read this variable. Internal callers
# (budget_inc / budget_reserve / budget_get / _pp_budget_*) MUST NOT use
# this — they call pp_budget_file_path() fresh per invocation.
PP_BUDGET_FILE="$(pp_budget_file_path)"
PP_BUDGET_LOCK="$(pp_budget_lock_path)"

# Internal: ensure the budget file's parent dir exists. mkdir -p is idempotent
# and a no-op when the dir is already there. Without this guard, the first of
# many parallel budget_inc callers can race against a missing PP_CACHE_DIR
# (observed on Ubuntu tmpfs CI runners: bats test 1 reported "No such file or
# directory" on the write redirect from one of 100 concurrent workers).
_pp_budget_ensure_dir() {
  mkdir -p "$(dirname "$(pp_budget_file_path)")" 2>/dev/null || true
}

_pp_budget_acquire() {
  _pp_budget_ensure_dir
  local _lock
  _lock=$(pp_budget_lock_path)
  local attempts=0
  while ! mkdir "$_lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -gt 250 ] && return 1
    sleep 0.02 2>/dev/null || sleep 1
  done
  return 0
}

_pp_budget_release() {
  rmdir "$(pp_budget_lock_path)" 2>/dev/null
}

# budget_inc: +1 under shared lock. Returns 0 on success, 1 on lock timeout.
budget_inc() {
  _pp_budget_acquire || return 1
  local _file
  _file=$(pp_budget_file_path)
  local cur
  cur=$(cat "$_file" 2>/dev/null || echo 0)
  echo $((cur + 1)) > "$_file"
  _pp_budget_release
  return 0
}

# budget_reserve N: +N if total stays <= PP_MAX_DAILY_CALLS, else refuse.
# Returns 0 reserved, 1 would-exceed-cap, 2 lock timeout.
budget_reserve() {
  local n="${1:?budget_reserve requires a count}"
  _pp_budget_acquire || return 2
  local _file
  _file=$(pp_budget_file_path)
  local cur
  cur=$(cat "$_file" 2>/dev/null || echo 0)
  if [ $((cur + n)) -le "$PP_MAX_DAILY_CALLS" ]; then
    echo $((cur + n)) > "$_file"
    _pp_budget_release
    return 0
  fi
  _pp_budget_release
  return 1
}

budget_get() {
  cat "$(pp_budget_file_path)" 2>/dev/null || echo 0
}

# pp_budget_remaining_pct
# Stdout: integer 0-100 representing remaining daily budget headroom.
# Clamps to [0, 100] so >cap stays at 0, not negative. Single source of
# truth for "how much budget is left" — consumed by statusline line-1
# pip, budget-aware idle fallback, and doctor budget-pressure check.
#
# Reuses budget_get to stay DRY with this lib's date-stamped path logic.
# No lock; reads are racy with concurrent budget_inc but we only need
# approximate state for UI/diagnostic.
pp_budget_remaining_pct() {
  local _max="$PP_MAX_DAILY_CALLS"
  # Guard: non-numeric or non-positive max → fall back to default cap.
  case "$_max" in
    ''|*[!0-9]*) _max=10000 ;;
  esac
  [ "$_max" -le 0 ] && _max=10000
  local _used
  _used=$(budget_get)
  # Guard: non-numeric → treat as 0 (optimistic, but safer than nan).
  case "$_used" in
    ''|*[!0-9]*) _used=0 ;;
  esac
  local _pct=$(( 100 * (_max - _used) / _max ))
  [ "$_pct" -lt 0 ] && _pct=0
  [ "$_pct" -gt 100 ] && _pct=100
  printf '%d' "$_pct"
}
