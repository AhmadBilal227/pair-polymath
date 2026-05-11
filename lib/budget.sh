#!/usr/bin/env bash
# Pair Polymath — budget tracking. Atomic via a SINGLE shared mkdir lock.
# Sourced by bin/statusline.sh. Requires PP_CACHE_DIR + PP_MAX_DAILY_CALLS in env.
#
# All mutations of PP_BUDGET_FILE serialize through ${PP_BUDGET_FILE}.lock.
# The prior split-lock design (.inc.lock vs .reserve.lock) allowed inc and
# reserve to race on the same file and lose updates.

PP_BUDGET_FILE="${PP_CACHE_DIR}/pp-budget-$(date +%Y%m%d).txt"
PP_BUDGET_LOCK="${PP_BUDGET_FILE}.lock"

_pp_budget_acquire() {
  local attempts=0
  while ! mkdir "$PP_BUDGET_LOCK" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -gt 50 ] && return 1
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
