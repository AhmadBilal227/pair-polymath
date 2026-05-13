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
  # R2 M1 fix: the R1 assertion was a substring match (`*"leak:"*`) that would
  # have green-passed if the loader left the placeholder LITERAL in the output
  # (e.g. `leak: ${OPENAI_API_KEY}`) — defeating the security guarantee.
  # Now we redirect stderr to /dev/null inside a subshell so bats' `$output`
  # captures stdout-only, and assert EXACT equality of the rendered line.
  PP_PROMPT_VAR_ALLOWLIST="name val" \
    run bash -c ". \"$PP_ROOT/lib/prompt-loader.sh\"; pp_render_prompt leakprobe 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-NEVER-LEAK-THIS"* ]]    # secret NOT substituted
  [[ "$output" != *'${OPENAI_API_KEY}'* ]]     # placeholder NOT left literal
  [ "$output" = "leak: " ]                     # exact: rendered empty
  unset OPENAI_API_KEY
}

@test "loader: placeholder ON allowlist substitutes normally" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  echo 'value: ${name}' > "$HOME/.claude/pair-polymath/prompts/normalprobe.md"
  PP_PROMPT_VAR_ALLOWLIST="name" name="Hello" run pp_render_prompt normalprobe
  [ "$status" -eq 0 ]
  [ "$output" = "value: Hello" ]
}

@test "loader: F3 — empty MEMORY_BLOCK sentinel block strips entirely" {
  # Template uses the same sentinel pattern as analyst-primary.md.
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  cat > "$HOME/.claude/pair-polymath/prompts/sentinel-probe.md" <<'EOF'
HEAD

<!-- MEMORY_BLOCK_START -->
${MEMORY_BLOCK}
<!-- MEMORY_BLOCK_END -->
TAIL
EOF
  PP_PROMPT_VAR_ALLOWLIST="MEMORY_BLOCK" MEMORY_BLOCK="" run pp_render_prompt sentinel-probe
  [ "$status" -eq 0 ]
  # Expect: "HEAD\n\nTAIL" — the empty block, both sentinels, and the
  # newline after the END sentinel are all stripped.
  expected=$'HEAD\n\nTAIL'
  [ "$output" = "$expected" ]
}

@test "loader: F3 — non-empty MEMORY_BLOCK strips only the sentinels" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  cat > "$HOME/.claude/pair-polymath/prompts/sentinel-probe2.md" <<'EOF'
HEAD

<!-- MEMORY_BLOCK_START -->
${MEMORY_BLOCK}
<!-- MEMORY_BLOCK_END -->
TAIL
EOF
  PP_PROMPT_VAR_ALLOWLIST="MEMORY_BLOCK" MEMORY_BLOCK="MEMORY CONTENT" run pp_render_prompt sentinel-probe2
  [ "$status" -eq 0 ]
  expected=$'HEAD\n\nMEMORY CONTENT\nTAIL'
  [ "$output" = "$expected" ]
}

@test "loader: default allowlist includes transcript_filtered and tool_summary (v0.4 Phase 1)" {
  # Source the loader in a subshell with allowlist UNSET so we observe
  # the file's compiled-in default value.
  out=$(unset PP_PROMPT_VAR_ALLOWLIST; . "${PP_ROOT}/lib/prompt-loader.sh"; printf '%s' "$PP_PROMPT_VAR_ALLOWLIST")
  case " $out " in
    *" transcript_filtered "*) ;;
    *) echo "transcript_filtered missing from default allowlist: $out" >&2; return 1 ;;
  esac
  case " $out " in
    *" tool_summary "*) ;;
    *) echo "tool_summary missing from default allowlist: $out" >&2; return 1 ;;
  esac
}

@test "loader: \${transcript_filtered} substitutes correctly when on allowlist" {
  mkdir -p "$HOME/.claude/pair-polymath/prompts"
  echo 'TRANSCRIPT:'$'\n''${transcript_filtered}'$'\n''END' > "$HOME/.claude/pair-polymath/prompts/tfilter.md"
  PP_PROMPT_VAR_ALLOWLIST="transcript_filtered" \
    transcript_filtered="USER: hi" \
    run pp_render_prompt tfilter
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'USER: hi'
}

@test "loader: F3 — analyst-primary off-mode is byte-identical to pre-2.3 fixture" {
  baseline="$PP_ROOT/test/fixtures/prompts/pre-2.3-analyst-baseline.txt"
  [ -f "$baseline" ]
  PP_PROMPT_VAR_ALLOWLIST="MEMORY_BLOCK lens_system_prompt_addition lens_examples lens_silent_example relevance_directive"
  MEMORY_BLOCK="" lens_system_prompt_addition="" lens_examples="" lens_silent_example="" relevance_directive=""
  out=$(pp_render_prompt analyst-primary)
  diff <(printf '%s' "$out") "$baseline"
}
