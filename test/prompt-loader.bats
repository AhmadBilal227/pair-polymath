#!/usr/bin/env bats
# Prompt loader: substitution, fallback resolution, missing-prompt error.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  # shellcheck disable=SC1091
  . "${PP_ROOT}/lib/prompt-loader.sh"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "loader: built-in prompt renders" {
  # Use any built-in prompt that exists
  run pp_render_prompt analyst-primary
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "loader: substitutes \${var} from environment" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  echo 'Hello, ${name}!' > "$HOME/.claude/pair-polymath/prompts/hello.md"
  name="World" run pp_render_prompt hello
  [ "$status" -eq 0 ]
  [ "$output" = "Hello, World!" ]
}

@test "loader: user override wins over built-in" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  echo 'USER_OVERRIDE' > "$HOME/.claude/pair-polymath/prompts/analyst-primary.md"
  run pp_render_prompt analyst-primary
  [ "$status" -eq 0 ]
  [ "$output" = "USER_OVERRIDE" ]
}

@test "loader: missing prompt → return 1 + stderr" {
  run pp_render_prompt does-not-exist
  [ "$status" -eq 1 ]
  [[ "$output" == *"prompt not found"* ]]
}

@test "loader: undefined \${var} substitutes empty string" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  echo 'Before ${undefined_var} After' > "$HOME/.claude/pair-polymath/prompts/test.md"
  run pp_render_prompt test
  [ "$status" -eq 0 ]
  [ "$output" = "Before  After" ]
}

@test "loader: multiple substitutions in one template" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  echo '${a} ${b} ${a}' > "$HOME/.claude/pair-polymath/prompts/multi.md"
  a="X" b="Y" run pp_render_prompt multi
  [ "$status" -eq 0 ]
  [ "$output" = "X Y X" ]
}
