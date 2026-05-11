#!/usr/bin/env bats
# polymath CLI: version, status, help, unknown command.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "polymath version: prints VERSION" {
  run bash "$PP_ROOT/bin/polymath" version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$PP_ROOT/VERSION")" ]
}

@test "polymath status: exits 0 with status info" {
  run bash "$PP_ROOT/bin/polymath" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pair Polymath status"* ]]
  [[ "$output" == *"Lenses loaded:"* ]]
}

@test "polymath help: lists subcommands" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"version"* ]]
}

@test "polymath: no args defaults to status" {
  run bash "$PP_ROOT/bin/polymath"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pair Polymath status"* ]]
}

@test "polymath: unknown command → exit 2 + stderr message" {
  run bash "$PP_ROOT/bin/polymath" nope 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
  [[ "$output" == *"polymath help"* ]]
}

@test "polymath disable: writes PP_EXTERNAL_LLM=0 to user.env" {
  # NOTE: setup() rebinds $HOME to a mktemp -d dir, so this path is in tmp.
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  run bash "$PP_ROOT/bin/polymath" disable
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM cycle disabled"* ]]
  grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath enable: writes PP_EXTERNAL_LLM=1 to user.env" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  run bash "$PP_ROOT/bin/polymath" enable
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM cycle enabled"* ]]
  grep -q '^PP_EXTERNAL_LLM=1$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath disable: idempotent (no duplicate lines after repeated calls)" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  local count
  count=$(grep -c '^PP_EXTERNAL_LLM=' "$CLAUDE_DIR/pair-polymath/config/user.env")
  [ "$count" -eq 1 ]
}

@test "polymath enable: clears a prior disable" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  bash "$PP_ROOT/bin/polymath" enable >/dev/null
  grep -q '^PP_EXTERNAL_LLM=1$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  ! grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath disable: preserves unrelated user.env lines" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  cat > "$CLAUDE_DIR/pair-polymath/config/user.env" <<'EOF'
# Custom setting kept across toggles
PP_MAX_DAILY_CALLS=2000
PP_MODEL=gpt-5
EOF
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  grep -q '^PP_MAX_DAILY_CALLS=2000$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  grep -q '^PP_MODEL=gpt-5$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  grep -q '^# Custom setting kept across toggles$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath disable: creates user.env if absent" {
  export CLAUDE_DIR="$HOME/.claude-fresh"
  # Note: parent dirs do not exist
  run bash "$PP_ROOT/bin/polymath" disable
  [ "$status" -eq 0 ]
  test -f "$CLAUDE_DIR/pair-polymath/config/user.env"
  grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath help: lists enable and disable as available subcommands" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"polymath enable"* ]]
  [[ "$output" == *"polymath disable"* ]]
  # Should no longer say "v0.2 will add: disable, enable"
  ! [[ "$output" == *"will add: disable"* ]]
  ! [[ "$output" == *"will add: enable"* ]]
}

# Regression for review fix M1: symlinked user.env must keep its symlink.
# Without the fix, mv replaces the symlink with a regular file in the .claude
# tree, silently breaking dotfile-manager setups.
@test "polymath disable: preserves symlink to dotfile-managed user.env" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  # Store the real file under a "dotfiles" directory and symlink user.env to it
  mkdir -p "$HOME/dotfiles"
  printf 'PP_MODEL=gpt-5\n' > "$HOME/dotfiles/user.env"
  ln -s "$HOME/dotfiles/user.env" "$CLAUDE_DIR/pair-polymath/config/user.env"

  bash "$PP_ROOT/bin/polymath" disable >/dev/null

  # Symlink must still exist
  [ -L "$CLAUDE_DIR/pair-polymath/config/user.env" ]
  # And its target must be the unchanged dotfile path
  resolved=$(readlink "$CLAUDE_DIR/pair-polymath/config/user.env")
  [ "$resolved" = "$HOME/dotfiles/user.env" ]
  # And the disable line was written THROUGH the symlink to the real file
  grep -q '^PP_EXTERNAL_LLM=0$' "$HOME/dotfiles/user.env"
  grep -q '^PP_MODEL=gpt-5$' "$HOME/dotfiles/user.env"
}

# Regression for review fix H1: read errors must not silently destroy user.env.
@test "polymath disable: unreadable user.env aborts with clear error" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  printf 'PP_MODEL=gpt-5\n' > "$CLAUDE_DIR/pair-polymath/config/user.env"
  # Pre-write something to make sure we don't silently nuke it
  chmod 000 "$CLAUDE_DIR/pair-polymath/config/user.env"

  run bash "$PP_ROOT/bin/polymath" disable
  # Root would still be able to read; running as non-root, grep exit > 1.
  # If we DO run as root in CI, this test should still find user.env intact
  # because the disable succeeded.
  chmod 644 "$CLAUDE_DIR/pair-polymath/config/user.env"

  if [ "$status" -ne 0 ]; then
    # Expected non-root path: failure + clear stderr, original file untouched
    [[ "$output" == *"failed to read"* ]] || [[ "$output" == *"left intact"* ]]
    grep -q '^PP_MODEL=gpt-5$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  else
    # Root path: disable succeeded; line was added
    grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  fi
}
