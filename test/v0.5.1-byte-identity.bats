#!/usr/bin/env bats
# v0.5.1 central invariant: STDOUT byte-identical to v0.5.0 with all flags off.
#
# This is the gate test for the cost-cut infrastructure release: with every
# PP_RETRY_ROUTER_*, PP_KPI_ENABLE, and PP_OAR_ENABLE flag at its default (0),
# bin/statusline.sh STDOUT on the canonical fixture must be sha256-identical
# to the v0.5.0 capture in test/fixtures/v0.5.0-baseline-stdout.txt.
#
# Known non-deterministic surfaces (stripped before hashing):
#   - Leading tick emoji (🪔/🪄/✨/💫 cycling every 2s from `date +%s`)
#   - Optional "cpu N.NN" segment (only emitted when system load >= 5.0)
#   - ANSI color escape codes (color palette can rotate by tick)
# After stripping these, the structural payload (insight text, freshness pip,
# idle marker) must match byte-for-byte between v0.5.0 and v0.5.1.

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

teardown() {
  rm -rf "$HOME"
}

# Normalize away known time-varying surfaces (perl -CSD = UTF-8 mode so
# the leading-emoji match can see multi-byte characters as one char):
#   - ANSI escape sequences (\x1b\[...m) — palette rotates by tick
#   - leading tick line that starts with one of (🪔 🪄 ✨ 💫) plus optional
#     " cpu N.NN" segment (only emitted when sysctl loadavg >= 5.0)
# Leaves the structural insight payload, which IS the invariant.
_pp_normalize_stdout() {
  perl -CSD -pe '
    s/\x1b\[[0-9;]*[A-Za-z]//g;
    s/^(?:\x{1FA94}|\x{1FA84}|\x{2728}|\x{1F4AB})(?:\s+cpu\s+\S+)?\s*\n//;
    s/^(?:\x{1FA94}|\x{1FA84}|\x{2728}|\x{1F4AB})\s*//;
  '
}

@test "byte-identity: baseline file exists and is non-empty" {
  [ -f "$PP_ROOT/test/fixtures/v0.5.0-baseline-stdout.txt" ]
  [ -s "$PP_ROOT/test/fixtures/v0.5.0-baseline-stdout.txt" ]
}

@test "byte-identity: v0.5.1 STDOUT with all flags off matches v0.5.0 baseline (normalized sha256)" {
  unset PP_RETRY_ROUTER_ENABLE PP_RETRY_ROUTER_SHADOW PP_KPI_ENABLE PP_OAR_ENABLE
  unset PP_RETRY_ROUTER_CANARY_PCT PP_RETRY_HARD_CAP_ENABLE

  local _baseline_file="$PP_ROOT/test/fixtures/v0.5.0-baseline-stdout.txt"
  [ -f "$_baseline_file" ] || skip "baseline file missing — capture via Task 19 procedure"

  local _baseline_norm
  _baseline_norm=$(_pp_normalize_stdout < "$_baseline_file")
  local _baseline_sha
  _baseline_sha=$(printf '%s' "$_baseline_norm" | shasum -a 256 | cut -d' ' -f1)

  local _current
  _current=$(cat "$PP_ROOT/test/fixtures/stdin-sample.json" \
    | bash "$PP_ROOT/bin/statusline.sh" 2>/dev/null)
  local _current_norm
  _current_norm=$(printf '%s' "$_current" | _pp_normalize_stdout)
  local _current_sha
  _current_sha=$(printf '%s' "$_current_norm" | shasum -a 256 | cut -d' ' -f1)

  # On mismatch, dump the diff for debugging.
  if [ "$_baseline_sha" != "$_current_sha" ]; then
    printf 'BASELINE sha: %s\n' "$_baseline_sha" >&2
    printf 'CURRENT  sha: %s\n' "$_current_sha" >&2
    printf '%s\n' "=== BASELINE (normalized) ===" >&2
    printf '%s\n' "$_baseline_norm" >&2
    printf '%s\n' "=== CURRENT (normalized) ===" >&2
    printf '%s\n' "$_current_norm" >&2
    diff <(printf '%s\n' "$_baseline_norm") <(printf '%s\n' "$_current_norm") >&2 || true
  fi
  [ "$_baseline_sha" = "$_current_sha" ]
}

@test "byte-identity: raw exit code is 0 with all flags off" {
  unset PP_RETRY_ROUTER_ENABLE PP_RETRY_ROUTER_SHADOW PP_KPI_ENABLE PP_OAR_ENABLE
  unset PP_RETRY_ROUTER_CANARY_PCT PP_RETRY_HARD_CAP_ENABLE
  run bash -c "cat '$PP_ROOT/test/fixtures/stdin-sample.json' | bash '$PP_ROOT/bin/statusline.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
}
