#!/usr/bin/env bats
# Prompt contracts: manifests, placeholder drift lint, and CLI surface.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$HOME/.claude"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/prompt-contract.sh"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "prompt contracts: all built-in manifests lint clean" {
  run pp_prompt_contract_lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt contracts: OK (9/9)"* ]]
}

@test "prompt contracts: list includes ids, versions, and owners" {
  run pp_prompt_contract_list
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ID\tVERSION\tOWNER'* ]]
  [[ "$output" == *$'analyst-primary\t0.5.4.0\tbin/statusline.sh'* ]]
  [[ "$output" == *$'router\t0.5.4.0\tlib/router.sh'* ]]
}

@test "prompt contracts: show prints one manifest as JSON" {
  run pp_prompt_contract_show router
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.id == "router" and (.input_variables | index("signals_json"))' >/dev/null
}

@test "prompt contracts: missing prompt id fails cleanly" {
  run pp_prompt_contract_show does-not-exist
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest not found"* ]]
}

@test "prompt contracts: lint catches undeclared placeholder drift" {
  fake="$PP_TEST_HOME/fake-root"
  mkdir -p "$fake/prompts/manifests" "$fake/test"
  printf 'Hello ${known} ${secret}\n' > "$fake/prompts/sample.md"
  printf '# placeholder\n' > "$fake/test/sample.bats"
  cat > "$fake/prompts/manifests/sample.json" <<'JSON'
{
  "id": "sample",
  "version": "0.0.1",
  "owner": "test",
  "description": "fixture",
  "template": "prompts/sample.md",
  "input_variables": ["known"],
  "output_schema": {"format": "text"},
  "security_boundary": {
    "trusted_instructions": "fixture",
    "untrusted_inputs": []
  },
  "eval_suites": ["test/sample.bats"]
}
JSON
  run bash -c "PP_ROOT='$fake'; . '$PP_ROOT/lib/prompt-contract.sh'; pp_prompt_contract_lint sample" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"placeholder drift"* ]]
  [[ "$output" == *"secret"* ]]
}

@test "polymath prompts: list/show/lint are wired" {
  run bash "$PP_ROOT/bin/polymath" prompts list
  [ "$status" -eq 0 ]
  [[ "$output" == *"analyst-primary"* ]]

  run bash "$PP_ROOT/bin/polymath" prompts show analyst-primary
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.id == "analyst-primary"' >/dev/null

  run bash "$PP_ROOT/bin/polymath" prompts lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt contracts: OK (9/9)"* ]]
}

@test "polymath help: lists prompts subcommand" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"polymath prompts"* ]]
}
