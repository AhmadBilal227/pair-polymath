#!/usr/bin/env bats
# v0.4.3 post-release hardening — regression tests for the 8 P0+P1 fixes
# surfaced by cumulative review of v0.4.0-4.2.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}

teardown() { rm -rf "$HOME"; }

# ============================================================
# P0-1: lib/budget.sh:9 midnight rollover
# ============================================================

@test "P0-1 midnight: budget_inc writes to TODAY's file even after source-time date" {
  # shellcheck source=../lib/budget.sh
  . "$PP_ROOT/lib/budget.sh"
  # Shadow pp_budget_file_path to simulate the clock moving forward.
  pp_budget_file_path() { printf '%s/pp-budget-20260101.txt' "$PP_CACHE_DIR"; }
  budget_inc
  [ "$(budget_get)" = "1" ]
  # Clock advances past midnight: pp_budget_file_path returns a new path.
  pp_budget_file_path() { printf '%s/pp-budget-20260102.txt' "$PP_CACHE_DIR"; }
  budget_inc
  # The NEW day's file should hold 1 (not 2 — independent counter), and the
  # OLD day's file should still exist with its 1 preserved.
  [ "$(budget_get)" = "1" ]
  [ -f "$PP_CACHE_DIR/pp-budget-20260101.txt" ]
  [ -f "$PP_CACHE_DIR/pp-budget-20260102.txt" ]
  [ "$(cat $PP_CACHE_DIR/pp-budget-20260101.txt)" = "1" ]
  [ "$(cat $PP_CACHE_DIR/pp-budget-20260102.txt)" = "1" ]
}

@test "P0-1 midnight: lock path is date-INDEPENDENT (single mkdir lock across the boundary)" {
  # shellcheck source=../lib/budget.sh
  . "$PP_ROOT/lib/budget.sh"
  local _l1 _l2
  _l1=$(pp_budget_lock_path)
  # Move "the clock" by overriding pp_budget_file_path; lock must NOT change.
  pp_budget_file_path() { printf '%s/pp-budget-20300101.txt' "$PP_CACHE_DIR"; }
  _l2=$(pp_budget_lock_path)
  [ "$_l1" = "$_l2" ]
  # And the lock path is in PP_CACHE_DIR, not /tmp.
  case "$_l1" in
    "$PP_CACHE_DIR"/*) : ;;
    *) false ;;
  esac
}

# ============================================================
# P0-2: hooks/inject-monitor-insight.sh:37 Linux stat fallback
# ============================================================

@test "P0-2 hook: stat fallback uses GNU '-c %Y' first then BSD '-f %m'" {
  # Locked-in invariant. Without the GNU fallback the freshness check
  # silently no-ops on Linux, injecting stale observations indefinitely.
  grep -qE 'stat -c %Y .* \|\| stat -f %m' "$PP_ROOT/hooks/inject-monitor-insight.sh"
}

# ============================================================
# P0-3: PP_MAX_DAILY_CALLS default unification (10000 everywhere)
# ============================================================

@test "P0-3 cap default: lib/budget.sh sets PP_MAX_DAILY_CALLS=10000 via :=" {
  # The `:` operator forces the default to be set on source, so every
  # downstream caller (bin/polymath status, pip, doctor, helper) reads
  # the same number even when the env var was unset before source.
  grep -qE '^: \"\$\{PP_MAX_DAILY_CALLS:=10000\}\"' "$PP_ROOT/lib/budget.sh"
}

@test "P0-3 cap default: sourcing lib/budget.sh with unset env sets PP_MAX_DAILY_CALLS=10000" {
  unset PP_MAX_DAILY_CALLS
  # shellcheck source=../lib/budget.sh
  . "$PP_ROOT/lib/budget.sh"
  [ "$PP_MAX_DAILY_CALLS" = "10000" ]
}

@test "P0-3 cap default: existing PP_MAX_DAILY_CALLS is NOT clobbered" {
  PP_MAX_DAILY_CALLS=5000
  # shellcheck source=../lib/budget.sh
  . "$PP_ROOT/lib/budget.sh"
  [ "$PP_MAX_DAILY_CALLS" = "5000" ]
}

# ============================================================
# P1-1: cache clear chmod 600 preserved budget files (doctor #17 stays green)
# ============================================================

@test "P1-1 cache clear: chmod 600 the preserved budget files (doctor #17 won't stay yellow)" {
  : > "$PP_CACHE_DIR/pp-budget-20260513.txt"
  chmod 644 "$PP_CACHE_DIR/pp-budget-20260513.txt"
  : > "$PP_CACHE_DIR/cc-monitor-fakesession-ENGINEERING.txt"
  run bash "$PP_ROOT/bin/polymath" cache clear
  [ "$status" -eq 0 ]
  [ -f "$PP_CACHE_DIR/pp-budget-20260513.txt" ]
  local _mode
  _mode=$(stat -c %a "$PP_CACHE_DIR/pp-budget-20260513.txt" 2>/dev/null \
    || stat -f %Lp "$PP_CACHE_DIR/pp-budget-20260513.txt" 2>/dev/null)
  [ "$_mode" = "600" ]
}

# ============================================================
# P1-2: cache clear sweeps idempotency hash + time files
# ============================================================

@test "P1-2 cache clear: sweeps cc-monitor-injected-{hash,time}-* idempotency files" {
  : > "$PP_CACHE_DIR/cc-monitor-injected-hash-fakesess-ENGINEERING.txt"
  : > "$PP_CACHE_DIR/cc-monitor-injected-time-fakesess-ENGINEERING.txt"
  : > "$PP_CACHE_DIR/cc-monitor-fakesess-ENGINEERING.txt"
  : > "$PP_CACHE_DIR/pp-budget-20260513.txt"
  run bash "$PP_ROOT/bin/polymath" cache clear
  [ "$status" -eq 0 ]
  ! [ -f "$PP_CACHE_DIR/cc-monitor-injected-hash-fakesess-ENGINEERING.txt" ]
  ! [ -f "$PP_CACHE_DIR/cc-monitor-injected-time-fakesess-ENGINEERING.txt" ]
  ! [ -f "$PP_CACHE_DIR/cc-monitor-fakesess-ENGINEERING.txt" ]
  # Budget file MUST survive (with mode 600 — also covered by P1-1).
  [ -f "$PP_CACHE_DIR/pp-budget-20260513.txt" ]
}

# ============================================================
# P1-3: cache clear --orphans uses date marker (portable >24h)
# ============================================================

@test "P1-3 orphan sweep: uses date marker for portable >24h semantics" {
  # We don't unit-test the marker-file dance directly (date arithmetic
  # portability is what the implementation is). Instead lock in the
  # presence of the marker-file pattern + the BSD-then-GNU fallback chain.
  grep -qF 'date -v -1d' "$PP_ROOT/bin/polymath"
  grep -qF "1 day ago" "$PP_ROOT/bin/polymath"
  grep -qF '! -newer' "$PP_ROOT/bin/polymath"
}

# ============================================================
# P1-4: README doc drift (cache files are 0600 in v0.4.2+)
# ============================================================

@test "P1-4 README: states cache files are 0600 (not the stale 0644 / manual chmod claim)" {
  # The pre-v0.4.2 docs said cache files were 0644 and told users to run
  # chmod manually. v0.4.2 made 0600 automatic; the README must match.
  grep -qE 'mode `0600` automatically' "$PP_ROOT/README.md"
  ! grep -qE 'chmod -R go-rwx' "$PP_ROOT/README.md"
}

@test "docs: README and installer defaults match current hooks and budget" {
  grep -qF 'statusLine + 3 hooks' "$PP_ROOT/README.md"
  grep -qF 'PP_MAX_DAILY_CALLS=10000' "$PP_ROOT/README.md"
  grep -qF 'PP_MAX_DAILY_CALLS=10000' "$PP_ROOT/docs/cost-model.md"
  grep -qF '| `PP_MAX_DAILY_CALLS` | `10000` |' "$PP_ROOT/docs/customization.md"
  grep -qF 'default 10000' "$PP_ROOT/bin/install.sh"
  grep -qF '22 health checks' "$PP_ROOT/CLAUDE.md"
  ! grep -qF '~247 tests' "$PP_ROOT/CLAUDE.md"
  ! grep -qF '12 health checks' "$PP_ROOT/CLAUDE.md"
  ! grep -qF 'bats-862' "$PP_ROOT/README.md"
  ! grep -qF '862/862 bats green' "$PP_ROOT/README.md"
  ! grep -qF 'PP_MAX_DAILY_CALLS=3500' "$PP_ROOT/docs/cost-model.md"
}

@test "docs: selected memory defaults match config/default.env" {
  local _alpha _max _batch
  _alpha=$(grep '^PP_MEMORY_RETRIEVAL_ALPHA=' "$PP_ROOT/config/default.env" | head -1 | sed 's/^[^=]*=//; s/[[:space:]].*$//')
  _max=$(grep '^PP_MEMORY_MAX_BYTES=' "$PP_ROOT/config/default.env" | head -1 | sed 's/^[^=]*=//; s/[[:space:]].*$//')
  _batch=$(grep '^PP_MEMORY_EVICT_BATCH_SIZE=' "$PP_ROOT/config/default.env" | head -1 | sed 's/^[^=]*=//; s/[[:space:]].*$//')
  grep -qF "| \`PP_MEMORY_RETRIEVAL_ALPHA\` | \`$_alpha\` |" "$PP_ROOT/docs/customization.md"
  grep -qF "| \`PP_MEMORY_MAX_BYTES\` | \`$_max\`" "$PP_ROOT/docs/customization.md"
  grep -qF "| \`PP_MEMORY_EVICT_BATCH_SIZE\` | \`$_batch\` |" "$PP_ROOT/docs/customization.md"
}

@test "docs: support policy tracks current major/minor line" {
  local _version _minor
  _version=$(cat "$PP_ROOT/VERSION")
  _minor=$(printf '%s' "$_version" | awk -F. '{printf "v%s.%s.x", $1, $2}')
  grep -qF "| $_minor" "$PP_ROOT/SECURITY.md"
  grep -qF "current $_minor line" "$PP_ROOT/docs/security.md"
  ! grep -qF 'v0.1.x-alpha' "$PP_ROOT/SECURITY.md"
}

# ============================================================
# P1-5: bin/polymath status threshold clamp backport (parity with pip + doctor)
# ============================================================

@test "P1-5 status: lower-bound clamp present (WARN/RED=0 won't trigger permanent yellow)" {
  grep -qE 'pressure_warn" -lt 1' "$PP_ROOT/bin/polymath"
  grep -qE 'pressure_red"  -lt 1' "$PP_ROOT/bin/polymath"
}

@test "P1-5 status: inversion-reset present (WARN >= RED resets to defaults)" {
  grep -qE 'pressure_warn" -ge "\$pressure_red"' "$PP_ROOT/bin/polymath"
}

@test "P1-5 status: smoke test with mis-configured WARN=0 RED=0 does not crash" {
  PP_BUDGET_WARN_PCT=0 PP_BUDGET_RED_PCT=0 run bash "$PP_ROOT/bin/polymath" status
  [ "$status" -eq 0 ]
  # Should still render the Budget line (defaults reset).
  printf '%s' "$output" | grep -qE 'Budget:'
}
