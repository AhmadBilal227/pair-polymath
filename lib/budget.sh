#!/usr/bin/env bash
# Pair Polymath — budget tracking. Atomic via mkdir locks.
# Sourced by bin/statusline.sh. Requires PP_CACHE_DIR + PP_MAX_DAILY_CALLS in env.

# Daily budget file rolls over by date
PP_BUDGET_FILE="${PP_CACHE_DIR}/pp-budget-$(date +%Y%m%d).txt"

# budget_inc: increment counter by 1, atomic
# Returns 0 on success, 1 on lock-acquisition failure (>50 attempts)
budget_inc() {
  local lock="${PP_BUDGET_FILE}.inc.lock"
  local attempts=0
  # Bounded busy-wait (50 attempts × 20ms = 1s max)
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -gt 50 ] && return 1
    sleep 0.02 2>/dev/null || sleep 1
  done
  local cur
  cur=$(cat "$PP_BUDGET_FILE" 2>/dev/null || echo 0)
  echo $((cur + 1)) > "$PP_BUDGET_FILE"
  rmdir "$lock" 2>/dev/null
  return 0
}

# budget_reserve N: atomically reserve N calls if total would stay <= PP_MAX_DAILY_CALLS
# Returns 0 if reservation succeeded, 1 if would exceed cap, 2 on lock failure
budget_reserve() {
  local n="${1:?budget_reserve requires a count}"
  local lock="${PP_BUDGET_FILE}.reserve.lock"
  local attempts=0
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -gt 50 ] && return 2
    sleep 0.02 2>/dev/null || sleep 1
  done
  local cur
  cur=$(cat "$PP_BUDGET_FILE" 2>/dev/null || echo 0)
  if [ $((cur + n)) -le "${PP_MAX_DAILY_CALLS:-3500}" ]; then
    echo $((cur + n)) > "$PP_BUDGET_FILE"
    rmdir "$lock" 2>/dev/null
    return 0
  fi
  rmdir "$lock" 2>/dev/null
  return 1
}

# budget_get: read current count
budget_get() {
  cat "$PP_BUDGET_FILE" 2>/dev/null || echo 0
}
