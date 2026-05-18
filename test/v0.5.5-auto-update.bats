#!/usr/bin/env bats
# v0.5.5 — auto-update subcommand + worker + subagent-statusline hook.
#
# Hermetic. Never touches the developer's real LaunchAgents / systemd /
# crontab — every test uses HOME=$(mktemp -d) and PP_AUTO_UPDATE_BACKEND
# to force the 'none' / 'cron' branches.

setup() {
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  HOME="$(mktemp -d)"
  export HOME
}

teardown() {
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] && rm -rf "$HOME"
}

# --- subagent-statusline hook -----------------------------------------------

@test "subagent-statusline: emits ⚛ row for polymath-named tasks" {
  run bash -c '
    printf "%s" "{\"tasks\":[{\"id\":\"t1\",\"name\":\"analyst-ux\",\"description\":\"UX lens\"}]}" \
      | bash "'"$PP_ROOT"'/hooks/subagent-statusline.sh"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '"id":"t1"'
  printf '%s\n' "$output" | grep -q '⚛ analyst-ux'
}

@test "subagent-statusline: passes through non-polymath tasks (no row emitted)" {
  run bash -c '
    printf "%s" "{\"tasks\":[{\"id\":\"x\",\"name\":\"user-task\",\"description\":\"unrelated\"}]}" \
      | bash "'"$PP_ROOT"'/hooks/subagent-statusline.sh"
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "subagent-statusline: jq missing → silent pass-through (rc 0, no output)" {
  # Use /usr/bin/env at an absolute path so PATH=/nonexistent doesn't break
  # the test shell itself; only the hook's own command-v jq lookup misses.
  run /usr/bin/env -i HOME="$HOME" PATH="/nonexistent" /bin/bash -c '
    printf "%s" "{}" | /bin/bash "'"$PP_ROOT"'/hooks/subagent-statusline.sh"
  '
  [ "$status" -eq 0 ]
}

@test "subagent-statusline: malformed JSON → rc 0 (Claude Code falls back)" {
  run bash -c '
    printf "%s" "not-json" | bash "'"$PP_ROOT"'/hooks/subagent-statusline.sh"
  '
  [ "$status" -eq 0 ]
}

# --- auto-update subcommand -------------------------------------------------

@test "auto-update help: prints usage" {
  run bash "$PP_ROOT/bin/polymath" auto-update help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "polymath auto-update"
  printf '%s\n' "$output" | grep -q "enable"
  printf '%s\n' "$output" | grep -q "disable"
  printf '%s\n' "$output" | grep -q "status"
}

@test "auto-update status: reports disabled when nothing is wired" {
  run env PP_AUTO_UPDATE_BACKEND=none bash "$PP_ROOT/bin/polymath" auto-update status
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "polymath auto-update: disabled"
}

@test "auto-update enable: --interval bogus rejected before scheduler touch" {
  run env PP_AUTO_UPDATE_BACKEND=none bash "$PP_ROOT/bin/polymath" auto-update enable --interval monthly
  [ "$status" -eq 2 ]
  # macOS grep treats --interval as a flag; -e disambiguates.
  printf '%s\n' "$output" | grep -qFe "--interval must be daily|weekly"
}

@test "auto-update enable: --time format rejected" {
  run env PP_AUTO_UPDATE_BACKEND=none bash "$PP_ROOT/bin/polymath" auto-update enable --time 9:5
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q "must be HH:MM"
}

@test "auto-update enable: --time out-of-range rejected (27:99)" {
  run env PP_AUTO_UPDATE_BACKEND=none bash "$PP_ROOT/bin/polymath" auto-update enable --time 27:99
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qE "00-23|00-59"
}

@test "auto-update enable: no scheduler → clear error, rc 2" {
  run env PP_AUTO_UPDATE_BACKEND=none bash "$PP_ROOT/bin/polymath" auto-update enable
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q "no scheduler found"
}

@test "auto-update disable: idempotent when nothing is enabled" {
  run env PP_AUTO_UPDATE_BACKEND=none bash "$PP_ROOT/bin/polymath" auto-update disable
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "already disabled"
}

@test "auto-update: appears in 'polymath help' usage" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "auto-update"
}

# --- worker -----------------------------------------------------------------

@test "auto-update worker: logs OK summary when update returns 0" {
  fake="$HOME/stub"
  mkdir -p "$fake/bin"
  cat > "$fake/bin/polymath" <<EOF
#!/usr/bin/env bash
echo "stub: \$@"
exit 0
EOF
  chmod +x "$fake/bin/polymath"
  cp "$PP_ROOT/bin/auto-update.sh" "$fake/bin/auto-update.sh"
  chmod +x "$fake/bin/auto-update.sh"

  run env PP_ROOT="$fake" PP_HOME="$HOME/pp" \
    bash "$fake/bin/auto-update.sh"
  [ "$status" -eq 0 ]
  [ -f "$HOME/pp/logs/auto-update.log" ]
  run cat "$HOME/pp/logs/auto-update.log"
  printf '%s\n' "$output" | grep -qE $'^[0-9].*\tOK\t.*rc=0$'
  printf '%s\n' "$output" | grep -q "stub: update --yes"
}

@test "auto-update worker: logs FAIL summary when update returns non-zero" {
  fake="$HOME/stub"
  mkdir -p "$fake/bin"
  cat > "$fake/bin/polymath" <<EOF
#!/usr/bin/env bash
echo "stub failed"
exit 5
EOF
  chmod +x "$fake/bin/polymath"
  cp "$PP_ROOT/bin/auto-update.sh" "$fake/bin/auto-update.sh"
  chmod +x "$fake/bin/auto-update.sh"

  run env PP_ROOT="$fake" PP_HOME="$HOME/pp" \
    bash "$fake/bin/auto-update.sh"
  # Worker exits 0 even on update failure (scheduler must not disable itself).
  [ "$status" -eq 0 ]
  run cat "$HOME/pp/logs/auto-update.log"
  printf '%s\n' "$output" | grep -qE $'^[0-9].*\tFAIL\t.*rc=5$'
}

@test "auto-update worker: concurrent lock → SKIP, no second update" {
  fake="$HOME/stub"
  mkdir -p "$fake/bin"
  # Counter file proves the update did NOT run.
  counter="$HOME/counter"
  echo 0 > "$counter"
  cat > "$fake/bin/polymath" <<EOF
#!/usr/bin/env bash
echo "ran"
n=\$(cat "$counter")
echo \$((n + 1)) > "$counter"
exit 0
EOF
  chmod +x "$fake/bin/polymath"
  cp "$PP_ROOT/bin/auto-update.sh" "$fake/bin/auto-update.sh"
  chmod +x "$fake/bin/auto-update.sh"

  # Pre-create a fresh lock dir so the second invocation sees it as held.
  lock="$HOME/pp-lock"
  mkdir -p "$lock"

  run env PP_ROOT="$fake" PP_HOME="$HOME/pp" PP_AUTO_UPDATE_LOCK="$lock" \
    bash "$fake/bin/auto-update.sh"
  [ "$status" -eq 0 ]
  # The counter should still be 0 — second invocation must have hit SKIP.
  run cat "$counter"
  [ "$output" = "0" ]
  run cat "$HOME/pp/logs/auto-update.log"
  printf '%s\n' "$output" | grep -q SKIP
}

@test "auto-update worker: stale lock (>1h) reclaimed by default" {
  fake="$HOME/stub"
  mkdir -p "$fake/bin"
  cat > "$fake/bin/polymath" <<EOF
#!/usr/bin/env bash
echo "ran"
exit 0
EOF
  chmod +x "$fake/bin/polymath"
  cp "$PP_ROOT/bin/auto-update.sh" "$fake/bin/auto-update.sh"
  chmod +x "$fake/bin/auto-update.sh"

  lock="$HOME/pp-lock"
  mkdir -p "$lock"
  # Backdate the lock 2h. Portable-ish: GNU -d, BSD -A; skip if neither works.
  touch -d "2 hours ago" "$lock" 2>/dev/null \
    || touch -A -020000 "$lock" 2>/dev/null \
    || skip "no portable mtime backdate"

  run env PP_ROOT="$fake" PP_HOME="$HOME/pp" PP_AUTO_UPDATE_LOCK="$lock" \
    bash "$fake/bin/auto-update.sh"
  [ "$status" -eq 0 ]
  run cat "$HOME/pp/logs/auto-update.log"
  printf '%s\n' "$output" | grep -qE 'OK.*rc=0'
}
