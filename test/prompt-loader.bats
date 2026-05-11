#!/usr/bin/env bats
# Prompt loader: substitution, fallback resolution, missing-prompt error.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  # Test fixtures use synthetic names (name, undefined_var, a, b, val) that
  # aren't on the production allowlist. Set the allowlist to include them so
  # the substitution-mechanics tests still work. The R1 security test below
  # has its own scope-narrowed allowlist.
  export PP_PROMPT_VAR_ALLOWLIST="name undefined_var a b val drop_reason"
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

# Regression test for review fix H1: a substitution VALUE that looks like a
# placeholder must NOT be re-scanned and expanded. If an LLM produces a
# critique reason of "${OPENAI_API_KEY}", the rendered prompt must contain
# that literal string, NOT the actual environment value.
@test "loader: substitution values are NOT re-scanned (secret-leak guard)" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  echo 'reason: ${drop_reason}' > "$HOME/.claude/pair-polymath/prompts/dropguard.md"
  export OPENAI_API_KEY="sk-NEVER-LEAK-THIS-12345"
  drop_reason='${OPENAI_API_KEY}' run pp_render_prompt dropguard
  [ "$status" -eq 0 ]
  # The literal "${OPENAI_API_KEY}" should appear in output, but NOT the secret
  [[ "$output" == *'${OPENAI_API_KEY}'* ]]
  [[ "$output" != *"sk-NEVER-LEAK-THIS"* ]]
  unset OPENAI_API_KEY
}

# Regression for the advance-past-match infinite-loop bug: a template with a
# stray `}` before a placeholder must still be processed correctly.
@test "loader: handles templates with stray } before placeholder" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  printf 'func() { return ${val}; }\n' > "$HOME/.claude/pair-polymath/prompts/strayrbrace.md"
  val="42" run pp_render_prompt strayrbrace
  [ "$status" -eq 0 ]
  [[ "$output" == *"return 42;"* ]]
}

# Ralph core R1 ai-engineer M8: a template referencing a name NOT on the
# allowlist must render empty for that placeholder — even if the env var is
# set. Defends against user-contributed prompt templates / lens
# system_prompt_addition fields that name a secret directly.
@test "loader: placeholder NOT in allowlist renders empty (R1 ai-engineer M8)" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  echo 'leak: ${OPENAI_API_KEY}' > "$HOME/.claude/pair-polymath/prompts/leakprobe.md"
  export OPENAI_API_KEY="sk-NEVER-LEAK-THIS-67890"
  # Scope allowlist to NOT include OPENAI_API_KEY.
  # bats' `run` merges stdout+stderr on newer versions (Ubuntu CI) but
  # not on macOS bash 3.2's older bats — strict-equality matching is
  # platform-fragile because we emit a "not in allowlist" warning to
  # stderr. Use substring assertions instead: key absent + prefix present.
  PP_PROMPT_VAR_ALLOWLIST="name val" run pp_render_prompt leakprobe
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-NEVER-LEAK-THIS"* ]]   # secret NOT substituted
  [[ "$output" == *"leak:"* ]]                # the literal prefix is present
  unset OPENAI_API_KEY
}

@test "loader: placeholder ON allowlist substitutes normally" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  echo 'value: ${name}' > "$HOME/.claude/pair-polymath/prompts/normalprobe.md"
  PP_PROMPT_VAR_ALLOWLIST="name" name="Hello" run pp_render_prompt normalprobe
  [ "$status" -eq 0 ]
  [ "$output" = "value: Hello" ]
}
