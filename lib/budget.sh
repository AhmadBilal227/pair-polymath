#!/usr/bin/env bash
# Pair Polymath — budget tracking. Atomic via a SINGLE shared mkdir lock.
# Sourced by bin/statusline.sh. Requires PP_CACHE_DIR + PP_MAX_DAILY_CALLS in env.
#
# All mutations of PP_BUDGET_FILE serialize through ${PP_BUDGET_FILE}.lock.
# The prior split-lock design (.inc.lock vs .reserve.lock) allowed inc and
# reserve to race on the same file and lose updates.

PP_BUDGET_FILE="${PP_CACHE_DIR}/pp-budget-$(date +%Y%m%d).txt"
PP_BUDGET_LOCK="${PP_BUDGET_FILE}.lock"

# Internal: ensure the budget file's parent dir exists. mkdir -p is idempotent
# and a no-op when the dir is already there. Without this guard, the first of
# many parallel budget_inc callers can race against a missing PP_CACHE_DIR
# (observed on Ubuntu tmpfs CI runners: bats test 1 reported "No such file or
# directory" on the write redirect from one of 100 concurrent workers).
_pp_budget_ensure_dir() {
  mkdir -p "$(dirname "$PP_BUDGET_FILE")" 2>/dev/null || true
}

_pp_budget_acquire() {
  _pp_budget_ensure_dir
  local attempts=0
  while ! mkdir "$PP_BUDGET_LOCK" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -gt 250 ] && return 1
    sleep 0.02 2>/dev/null || sleep 1
  done
  return 0
}

_pp_budget_release() {
  rmdir "$PP_BUDGET_LOCK" 2>/dev/null
}

# budget_inc: +1 under shared lock. Returns 0 on success, 1 on lock timeout.
budget_inc() {
  _pp_budget_acquire || return 1
  local cur
  cur=$(cat "$PP_BUDGET_FILE" 2>/dev/null || echo 0)
  echo $((cur + 1)) > "$PP_BUDGET_FILE"
  _pp_budget_release
  return 0
}

# budget_reserve N: +N if total stays <= PP_MAX_DAILY_CALLS, else refuse.
# Returns 0 reserved, 1 would-exceed-cap, 2 lock timeout.
budget_reserve() {
  local n="${1:?budget_reserve requires a count}"
  _pp_budget_acquire || return 2
  local cur
  cur=$(cat "$PP_BUDGET_FILE" 2>/dev/null || echo 0)
  if [ $((cur + n)) -le "${PP_MAX_DAILY_CALLS:-3500}" ]; then
    echo $((cur + n)) > "$PP_BUDGET_FILE"
    _pp_budget_release
    return 0
  fi
  _pp_budget_release
  return 1
}

budget_get() {
  cat "$PP_BUDGET_FILE" 2>/dev/null || echo 0
}

# pp_budget_remaining_pct
# Stdout: integer 0-100 representing remaining daily budget headroom.
# Clamps to [0, 100] so >cap stays at 0, not negative. Single source of
# truth for "how much budget is left" — consumed by statusline line-1
# pip, budget-aware idle fallback, and doctor budget-pressure check.
#
# Reuses PP_BUDGET_FILE + budget_get to stay DRY with this lib's
# date-stamped path logic. No lock; reads are racy with concurrent
# budget_inc but we only need approximate state for UI/diagnostic.
pp_budget_remaining_pct() {
  local _max="${PP_MAX_DAILY_CALLS:-10000}"
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
