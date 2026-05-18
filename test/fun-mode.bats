#!/usr/bin/env bats
# Display-only fun mode helpers and CLI.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$PP_TEST_HOME/.claude"
  mkdir -p "$CLAUDE_DIR"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "fun mode: off means no output" {
  run bash -c '. "$PP_ROOT/lib/fun-mode.sh"; PP_FUN_MODE=0 pp_fun_render'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "fun mode: normalizes style, intensity, cooldown, and max chars" {
  run bash -c '. "$PP_ROOT/lib/fun-mode.sh"; printf "%s/%s/%s/%s\n" "$(pp_fun_style_normalize odd)" "$(pp_fun_intensity_normalize 99)" "$(pp_fun_cooldown_s_normalize 999999)" "$(pp_fun_max_chars_normalize 999)"'
  [ "$status" -eq 0 ]
  [ "$output" = "mentor/1/86400/240" ]
}

@test "fun mode: roast style is gated and falls back to dry copy" {
  run bash -c '. "$PP_ROOT/lib/fun-mode.sh"; PP_FUN_MODE=1 PP_FUN_COOLDOWN_S=0 PP_FUN_STYLE=roast PP_FUN_ALLOW_ROAST=0 PP_FUN_TEST_ERROR=true pp_fun_render'
  [ "$status" -eq 0 ]
  [[ "$output" == *"test suite has filed a complaint"* ]]
  [[ "$output" != *"process is trying"* ]]
}

@test "fun mode: roast style renders only with explicit allow flag" {
  run bash -c '. "$PP_ROOT/lib/fun-mode.sh"; PP_FUN_MODE=1 PP_FUN_COOLDOWN_S=0 PP_FUN_STYLE=roast PP_FUN_ALLOW_ROAST=1 PP_FUN_TEST_ERROR=true pp_fun_render'
  [ "$status" -eq 0 ]
  [[ "$output" == *"process is trying"* ]]
}

@test "fun mode: max chars is enforced" {
  run bash -c '. "$PP_ROOT/lib/fun-mode.sh"; PP_FUN_MODE=1 PP_FUN_COOLDOWN_S=0 PP_FUN_STYLE=founder PP_FUN_CONTEXT_PCT=90 PP_FUN_MAX_CHARS=40 pp_fun_render'
  [ "$status" -eq 0 ]
  [ "${#output}" -le 40 ]
}

@test "fun mode: cooldown suppresses repeated renders until the window passes" {
  cooldown_file="$HOME/fun.last"
  run env PP_FUN_MODE=1 PP_FUN_STYLE=mentor PP_FUN_COOLDOWN_FILE="$cooldown_file" PP_FUN_COOLDOWN_S=300 PP_FUN_NOW=1000 \
    bash -c '. "$PP_ROOT/lib/fun-mode.sh"; pp_fun_render'
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  run env PP_FUN_MODE=1 PP_FUN_STYLE=mentor PP_FUN_COOLDOWN_FILE="$cooldown_file" PP_FUN_COOLDOWN_S=300 PP_FUN_NOW=1100 \
    bash -c '. "$PP_ROOT/lib/fun-mode.sh"; pp_fun_render'
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  run env PP_FUN_MODE=1 PP_FUN_STYLE=mentor PP_FUN_COOLDOWN_FILE="$cooldown_file" PP_FUN_COOLDOWN_S=300 PP_FUN_NOW=1301 \
    bash -c '. "$PP_ROOT/lib/fun-mode.sh"; pp_fun_render'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "polymath fun: on, style, status, and off update user.env" {
  run bash "$PP_ROOT/bin/polymath" fun on
  [ "$status" -eq 0 ]
  user_env="$CLAUDE_DIR/pair-polymath/config/user.env"
  grep -q '^PP_FUN_MODE=1$' "$user_env"

  run bash "$PP_ROOT/bin/polymath" fun style roast
  [ "$status" -eq 0 ]
  grep -q '^PP_FUN_STYLE=roast$' "$user_env"
  grep -q '^PP_FUN_ALLOW_ROAST=1$' "$user_env"

  run bash "$PP_ROOT/bin/polymath" fun status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pair Polymath fun mode"* ]]
  [[ "$output" == *"Enabled:   1"* ]]
  [[ "$output" == *"Style:     roast"* ]]

  run bash "$PP_ROOT/bin/polymath" fun off
  [ "$status" -eq 0 ]
  grep -q '^PP_FUN_MODE=0$' "$user_env"
}

@test "statusline fun mode: renders only from safe derived signals" {
  mkdir -p "$CLAUDE_DIR/pair-polymath/config" "$CLAUDE_DIR/cache"
  cat > "$CLAUDE_DIR/pair-polymath/config/user.env" <<'EOF'
PP_EXTERNAL_LLM=0
PP_FUN_MODE=1
PP_FUN_STYLE=mentor
PP_FUN_COOLDOWN_S=0
EOF
  printf 'ERROR: true\n' > "$CLAUDE_DIR/cache/cc-test-smoke-test-session.cache"

  run bash -c "cat '$PP_ROOT/test/fixtures/stdin-sample.json' | bash '$PP_ROOT/bin/statusline.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Loop risk"* ]]
  [[ "$output" != *"ERROR: true"* ]]
  [[ "$output" != *"nonexistent-transcript"* ]]
}

@test "fun mode: no hook or analyst prompt injection surface" {
  ! grep -R "PP_FUN\\|pp_fun\\|fun-mode" "$PP_ROOT/hooks" "$PP_ROOT/prompts" >/dev/null 2>&1
}
