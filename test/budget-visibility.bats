#!/usr/bin/env bats
# v0.4.1 — Budget-visibility helpers + UX surfaces.
# Tests resolve the 'only seeing tip rotation, no lens insights' bug:
# polymath stops producing lens observations when daily budget is
# exhausted; the user can't tell that's the cause.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  # shellcheck source=../lib/budget.sh
  . "$PP_ROOT/lib/budget.sh"
}

teardown() { rm -rf "$HOME"; }

_strip_ansi() {
  # Strip color/ANSI escapes so percent-pattern assertions are robust.
  LC_ALL=C sed -E $'s/\x1B\\[[0-9;]*[mGKH]//g'
}

# ============================================================
# Task 1 — pp_budget_remaining_pct helper
# ============================================================

@test "helper: pp_budget_remaining_pct returns 100 when no calls today" {
  PP_MAX_DAILY_CALLS=10000 run pp_budget_remaining_pct
  [ "$status" -eq 0 ]
  [ "$output" -eq 100 ]
}

@test "helper: pp_budget_remaining_pct returns 50 at half cap" {
  echo 5000 > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=10000 run pp_budget_remaining_pct
  [ "$status" -eq 0 ]
  [ "$output" -eq 50 ]
}

@test "helper: pp_budget_remaining_pct clamps to 0 when over cap (NOT negative)" {
  echo 12000 > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=10000 run pp_budget_remaining_pct
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "helper: pp_budget_remaining_pct returns 100 when budget file has garbage" {
  # GPT plan-review I4: validate-and-clamp the env reads.
  echo "garbage-not-a-number" > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=10000 run pp_budget_remaining_pct
  [ "$status" -eq 0 ]
  [ "$output" -eq 100 ]
}

@test "helper: pp_budget_remaining_pct survives PP_MAX_DAILY_CALLS=0 (degenerate)" {
  echo 100 > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=0 run pp_budget_remaining_pct
  [ "$status" -eq 0 ]
  # Falls back to default cap 10000 → 100-100/10000 = 99% remaining.
  [ "$output" -eq 99 ]
}

# ============================================================
# Task 2 — PP_DISPLAY_STALE_S scales with PP_PARALLEL_INTERVAL_S
# ============================================================

@test "statusline: PP_DISPLAY_STALE_S default scales via user.env PP_PARALLEL_INTERVAL_S" {
  # GPT plan-review I1: real integration test, not formula reimpl.
  # config/default.env overrides shell env by design (12-factor opposite,
  # intentional for install-consistency), so we drop a user.env override
  # which IS sourced AFTER default.env per lib/config.sh resolution order.
  mkdir -p "$HOME/.claude/pair-polymath/config"
  printf 'PP_PARALLEL_INTERVAL_S=400\n' > "$HOME/.claude/pair-polymath/config/user.env"
  run bash -c "
    printf '{\"session_id\":\"bats-stale-1\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"\$(pwd)\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  # 3*400 = 1200 → 1200/60 = 20m in the idle message.
  printf '%s' "$output" | _strip_ansi | grep -qE 'in last 20m'
}

@test "statusline: PP_DISPLAY_STALE_S floor 900 when user.env interval is low" {
  mkdir -p "$HOME/.claude/pair-polymath/config"
  printf 'PP_PARALLEL_INTERVAL_S=60\n' > "$HOME/.claude/pair-polymath/config/user.env"
  run bash -c "
    printf '{\"session_id\":\"bats-stale-2\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"\$(pwd)\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  # max(900, 3*60) = 900 → 900/60 = 15m
  printf '%s' "$output" | _strip_ansi | grep -qE 'in last 15m'
}

# ============================================================
# Task 3 — Line-1 budget pip
# ============================================================

@test "line-1 pip: amber ⚡ when 80% used (20% remaining), with exact pct" {
  echo 8000 > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=10000 \
    PP_BUDGET_WARN_PCT=80 PP_BUDGET_RED_PCT=95 \
  run bash -c "
    printf '{\"session_id\":\"bats-pip-amber\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"\$(pwd)\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  # GPT plan-review I2: assert exact glyph+percent.
  line1=$(printf '%s' "$output" | head -1 | _strip_ansi)
  printf '%s' "$line1" | grep -qF '⚡20%'
  # Red glyph must NOT appear at 80% used.
  ! printf '%s' "$line1" | grep -qF '⚠'
}

@test "line-1 pip: red ⚠ when 95% used (5% remaining), with exact pct" {
  echo 9500 > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=10000 \
    PP_BUDGET_WARN_PCT=80 PP_BUDGET_RED_PCT=95 \
  run bash -c "
    printf '{\"session_id\":\"bats-pip-red\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"\$(pwd)\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  line1=$(printf '%s' "$output" | head -1 | _strip_ansi)
  printf '%s' "$line1" | grep -qF '⚠5%'
}

@test "line-1 pip: NO pip glyph at <80% used (healthy)" {
  echo 100 > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=10000 \
  run bash -c "
    printf '{\"session_id\":\"bats-pip-none\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"\$(pwd)\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  # Neither glyph in line 1 at 1% used (99% remaining).
  line1=$(printf '%s' "$output" | head -1 | _strip_ansi)
  ! printf '%s' "$line1" | grep -qE '⚡|⚠'
}

# ============================================================
# Task 4 — Budget-aware idle fallback
# ============================================================

@test "idle fallback: 'paused — daily budget reached' at 95%+ used" {
  echo 9700 > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=10000 \
    PP_BUDGET_WARN_PCT=80 PP_BUDGET_RED_PCT=95 \
  run bash -c "
    printf '{\"session_id\":\"bats-idle-paused\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"\$(pwd)\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | _strip_ansi | grep -qE 'paused — daily budget reached'
}

@test "idle fallback: 'budget at N% remaining' at 80-94% used" {
  echo 8500 > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=10000 \
    PP_BUDGET_WARN_PCT=80 PP_BUDGET_RED_PCT=95 \
  run bash -c "
    printf '{\"session_id\":\"bats-idle-warn\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"\$(pwd)\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | _strip_ansi | grep -qE 'budget at 15% remaining'
}

@test "idle fallback: generic 'no fresh insight' at <80% used (healthy)" {
  echo 100 > "$PP_CACHE_DIR/pp-budget-$(date +%Y%m%d).txt"
  PP_MAX_DAILY_CALLS=10000 \
  run bash -c "
    printf '{\"session_id\":\"bats-idle-healthy\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"\$(pwd)\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  # Should fall to the healthy generic message OR a tip line. Not the budget one.
  ! printf '%s' "$output" | _strip_ansi | grep -qE 'budget reached|budget at [0-9]+% remaining'
}
