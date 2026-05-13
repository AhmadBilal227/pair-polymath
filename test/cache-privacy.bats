#!/usr/bin/env bats
# v0.4.2 — per-project TIP_CACHE + permission lockdown + `polymath cache` CLI.
# Closes the privacy leak where tips generated from project A's CLAUDE.md
# (e.g. "App.tsx is technical debt") rotated through every other project's
# statusline because cc-tips.txt was a single global file.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  # shellcheck source=../lib/grounding.sh
  . "$PP_ROOT/lib/grounding.sh"
}

teardown() { rm -rf "$HOME"; }

# ============================================================
# pp_project_key — the keying helper
# ============================================================

@test "project_key: deterministic — same cwd returns same key on repeat call" {
  local _dir="$HOME/proj-a"
  mkdir -p "$_dir"
  local _k1 _k2
  _k1=$(pp_project_key "$_dir")
  _k2=$(pp_project_key "$_dir")
  [ "$_k1" = "$_k2" ]
  # 16 hex chars (G6: bumped from 12 to reduce birthday collision risk)
  [ "${#_k1}" -eq 16 ]
  printf '%s' "$_k1" | grep -qE '^[0-9a-f]{16}$'
}

@test "project_key: different cwds → different keys" {
  local _a="$HOME/proj-a" _b="$HOME/proj-b"
  mkdir -p "$_a" "$_b"
  local _ka _kb
  _ka=$(pp_project_key "$_a")
  _kb=$(pp_project_key "$_b")
  [ "$_ka" != "$_kb" ]
}

@test "project_key: git toplevel collapses subdirs to one key" {
  local _root="$HOME/gitproj"
  mkdir -p "$_root/src/deep"
  (cd "$_root" && git init -q 2>/dev/null && git config user.email t@t && git config user.name t && git commit --allow-empty -qm init 2>/dev/null) || skip "git unavailable"
  local _kroot _ksub
  _kroot=$(pp_project_key "$_root")
  _ksub=$(pp_project_key "$_root/src/deep")
  # Both must hash the same toplevel → same key.
  [ "$_kroot" = "$_ksub" ]
}

@test "project_key: empty/missing cwd → 16 zeros (unknown bucket, not silent absent)" {
  local _k1 _k2
  _k1=$(pp_project_key "")
  _k2=$(pp_project_key "/this/does/not/exist")
  [ "$_k1" = "0000000000000000" ]
  [ "$_k2" = "0000000000000000" ]
}

# ============================================================
# Statusline — uses per-project TIP_CACHE, files are mode 600
# ============================================================

@test "statusline: writes per-project tip cache, not the legacy global file" {
  local _cwd="$HOME/myproj"
  mkdir -p "$_cwd"
  run bash -c "
    printf '{\"session_id\":\"bats-tipcache\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"$_cwd\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  # The legacy global file MUST NOT be created.
  ! [ -f "$PP_CACHE_DIR/cc-tips.txt" ]
  # Review G10: tighten the assertion. Any cc-tips* file present MUST match
  # the keyed pattern cc-tips-<16hex>.txt — a tautological "ge 0" check
  # would pass even if the bug regressed.
  local _bad
  _bad=$(find "$PP_CACHE_DIR" -maxdepth 1 -name 'cc-tips*' -type f 2>/dev/null \
    | grep -vE '/cc-tips-[0-9a-f]{16}\.txt$' | wc -l | tr -d ' ')
  [ "$_bad" -eq 0 ]
}

@test "umask: statusline.sh declares 'umask 077' at the top" {
  # Locked-in invariant — every cache write inside statusline.sh inherits 600.
  grep -qE '^umask 077\s*$' "$PP_ROOT/bin/statusline.sh"
}

@test "umask: inject hook declares 'umask 077'" {
  grep -qE '^umask 077\s*$' "$PP_ROOT/hooks/inject-monitor-insight.sh"
}

@test "umask: bin/polymath declares 'umask 077'" {
  grep -qE '^umask 077\s*$' "$PP_ROOT/bin/polymath"
}

@test "umask: with umask 077, file mode is 600 (the actual invariant)" {
  # Belt-and-suspenders: proves the umask value chosen actually produces 600,
  # so a future contributor can't drift to umask 027 (640) thinking it's fine.
  run bash -c "umask 077; : > '$PP_CACHE_DIR/probe.txt'"
  [ "$status" -eq 0 ]
  local _mode
  _mode=$(stat -c %Lp "$PP_CACHE_DIR/probe.txt" 2>/dev/null || stat -f %Lp "$PP_CACHE_DIR/probe.txt" 2>/dev/null)
  [ "$_mode" = "600" ]
}

@test "statusline: tightens cache parent dir to 700 even if pre-existing was 755" {
  chmod 755 "$PP_CACHE_DIR"
  run bash -c "
    printf '{\"session_id\":\"bats-dirmode\",\"model\":{\"display_name\":\"S\"},\"workspace\":{\"current_dir\":\"$HOME\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0}}' \
      | bash '$PP_ROOT/bin/statusline.sh'
  "
  [ "$status" -eq 0 ]
  local _mode
  _mode=$(stat -c %Lp "$PP_CACHE_DIR" 2>/dev/null || stat -f %Lp "$PP_CACHE_DIR" 2>/dev/null)
  [ "$_mode" = "700" ]
}

# ============================================================
# `polymath cache` CLI
# ============================================================

@test "cli: 'polymath cache list' reports loose-perm files" {
  : > "$PP_CACHE_DIR/cc-tips-leaky.txt"
  chmod 644 "$PP_CACHE_DIR/cc-tips-leaky.txt"
  run bash "$PP_ROOT/bin/polymath" cache list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qE 'mode != 600'
}

@test "cli: 'polymath cache clear' removes lens + tip caches, preserves budget files" {
  # Seed: one lens cache, one tip cache, one budget file.
  : > "$PP_CACHE_DIR/cc-monitor-fakesession-ENGINEERING.txt"
  : > "$PP_CACHE_DIR/cc-tips-deadbeef0000.txt"
  : > "$PP_CACHE_DIR/cc-monitor-budget-20260513.txt"
  run bash "$PP_ROOT/bin/polymath" cache clear
  [ "$status" -eq 0 ]
  ! [ -f "$PP_CACHE_DIR/cc-monitor-fakesession-ENGINEERING.txt" ]
  ! [ -f "$PP_CACHE_DIR/cc-tips-deadbeef0000.txt" ]
  # Budget file MUST survive — daily cap tracking can't be reset.
  [ -f "$PP_CACHE_DIR/cc-monitor-budget-20260513.txt" ]
}

@test "cli: 'polymath cache clear --tips' wipes ONLY tip caches" {
  : > "$PP_CACHE_DIR/cc-monitor-fake-ENGINEERING.txt"
  : > "$PP_CACHE_DIR/cc-tips-abc123def456.txt"
  : > "$PP_CACHE_DIR/cc-tips.txt"
  run bash "$PP_ROOT/bin/polymath" cache clear --tips
  [ "$status" -eq 0 ]
  ! [ -f "$PP_CACHE_DIR/cc-tips-abc123def456.txt" ]
  ! [ -f "$PP_CACHE_DIR/cc-tips.txt" ]
  [ -f "$PP_CACHE_DIR/cc-monitor-fake-ENGINEERING.txt" ]
}

@test "cli: 'polymath cache' (no subcmd) defaults to list" {
  run bash "$PP_ROOT/bin/polymath" cache
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qE 'Pair Polymath cache'
}

@test "cli: 'polymath cache <bad>' exits non-zero with hint" {
  run bash "$PP_ROOT/bin/polymath" cache nonsense
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qE 'unknown subcommand'
}

# ============================================================
# Doctor check #17
# ============================================================

@test "doctor: cache-permissions check green when dir 700 + all files 600" {
  : > "$PP_CACHE_DIR/cc-monitor-foo.txt"
  chmod 600 "$PP_CACHE_DIR/cc-monitor-foo.txt"
  chmod 700 "$PP_CACHE_DIR"
  # shellcheck source=../lib/doctor.sh
  . "$PP_ROOT/lib/doctor.sh"
  run doctor_check_cache_permissions
  [ "$status" -eq 0 ]
}

@test "doctor: cache-permissions yellow when file is 644" {
  : > "$PP_CACHE_DIR/cc-tips-leak.txt"
  chmod 644 "$PP_CACHE_DIR/cc-tips-leak.txt"
  chmod 700 "$PP_CACHE_DIR"
  # shellcheck source=../lib/doctor.sh
  . "$PP_ROOT/lib/doctor.sh"
  run doctor_check_cache_permissions
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qE 'mode != 600'
}

@test "doctor: cache-permissions yellow when dir is 755 (not 700)" {
  : > "$PP_CACHE_DIR/cc-monitor-ok.txt"
  chmod 600 "$PP_CACHE_DIR/cc-monitor-ok.txt"
  chmod 755 "$PP_CACHE_DIR"
  # shellcheck source=../lib/doctor.sh
  . "$PP_ROOT/lib/doctor.sh"
  run doctor_check_cache_permissions
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qE 'mode is 755'
}
