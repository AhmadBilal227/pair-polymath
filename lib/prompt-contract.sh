#!/usr/bin/env bash
# Pair Polymath — prompt contract manifests and linting.
#
# Runtime prompts remain plain Markdown under prompts/*.md. The contract layer
# stores metadata under prompts/manifests/*.json so prompt changes can be
# versioned, linted, and tied back to eval coverage without changing the
# hot-path prompt loader.

if [ -z "${PP_ROOT:-}" ]; then
  _pp_pc_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
  PP_ROOT="$_pp_pc_self_dir"
  unset _pp_pc_self_dir
fi

_pp_prompt_contract_manifest_dir() {
  printf '%s/prompts/manifests' "$PP_ROOT"
}

_pp_prompt_contract_prompt_path() {
  printf '%s/prompts/%s.md' "$PP_ROOT" "$1"
}

_pp_prompt_contract_manifest_path() {
  printf '%s/%s.json' "$(_pp_prompt_contract_manifest_dir)" "$1"
}

_pp_prompt_contract_names() {
  local _dir
  _dir=$(_pp_prompt_contract_manifest_dir)
  [ -d "$_dir" ] || return 0
  find "$_dir" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null \
    | sed 's|.*/||; s|\.json$||' \
    | LC_ALL=C sort
}

_pp_prompt_contract_template_names() {
  find "$PP_ROOT/prompts" -maxdepth 1 -type f -name '*.md' -print 2>/dev/null \
    | sed 's|.*/||; s|\.md$||' \
    | LC_ALL=C sort
}

_pp_prompt_contract_placeholders() {
  local _path="$1"
  grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$_path" 2>/dev/null \
    | sed 's/^\${//; s/}$//' \
    | LC_ALL=C sort -u
}

_pp_prompt_contract_err() {
  printf 'prompt-contract: %s\n' "$*" >&2
}

_pp_prompt_contract_json_string() {
  local _manifest="$1" _expr="$2"
  jq -e "${_expr} | type == \"string\" and length > 0" "$_manifest" >/dev/null 2>&1
}

_pp_prompt_contract_json_array() {
  local _manifest="$1" _expr="$2"
  jq -e "${_expr} | type == \"array\"" "$_manifest" >/dev/null 2>&1
}

_pp_prompt_contract_list_eval_suites_missing() {
  local _manifest="$1"
  jq -r '.eval_suites[]?' "$_manifest" 2>/dev/null | while IFS= read -r _suite; do
    [ -z "$_suite" ] && continue
    [ -e "$PP_ROOT/$_suite" ] || printf '%s\n' "$_suite"
  done
}

pp_prompt_contract_lint_one() {
  local _name="$1"
  local _manifest _prompt
  _manifest=$(_pp_prompt_contract_manifest_path "$_name")
  _prompt=$(_pp_prompt_contract_prompt_path "$_name")

  if [ ! -f "$_manifest" ]; then
    _pp_prompt_contract_err "$_name: missing manifest $_manifest"
    return 1
  fi
  if [ ! -f "$_prompt" ]; then
    _pp_prompt_contract_err "$_name: missing template $_prompt"
    return 1
  fi
  if ! jq empty "$_manifest" >/dev/null 2>&1; then
    _pp_prompt_contract_err "$_name: manifest is not valid JSON"
    return 1
  fi

  local _id _template _bad_vars _actual _declared _missing_eval
  _id=$(jq -r '.id // ""' "$_manifest")
  if [ "$_id" != "$_name" ]; then
    _pp_prompt_contract_err "$_name: manifest id mismatch (got $_id)"
    return 1
  fi
  case "$_id" in
    [a-z][a-z0-9-]*) ;;
    *)
      _pp_prompt_contract_err "$_name: id must match [a-z][a-z0-9-]*"
      return 1
      ;;
  esac

  _template=$(jq -r '.template // ""' "$_manifest")
  if [ "$_template" != "prompts/${_name}.md" ]; then
    _pp_prompt_contract_err "$_name: template must be prompts/${_name}.md"
    return 1
  fi

  if ! _pp_prompt_contract_json_string "$_manifest" '.version'; then
    _pp_prompt_contract_err "$_name: version must be a non-empty string"
    return 1
  fi
  if ! _pp_prompt_contract_json_string "$_manifest" '.owner'; then
    _pp_prompt_contract_err "$_name: owner must be a non-empty string"
    return 1
  fi
  if ! _pp_prompt_contract_json_string "$_manifest" '.description'; then
    _pp_prompt_contract_err "$_name: description must be a non-empty string"
    return 1
  fi
  if ! _pp_prompt_contract_json_array "$_manifest" '.input_variables'; then
    _pp_prompt_contract_err "$_name: input_variables must be an array"
    return 1
  fi
  if ! _pp_prompt_contract_json_array "$_manifest" '.eval_suites'; then
    _pp_prompt_contract_err "$_name: eval_suites must be an array"
    return 1
  fi
  if ! jq -e '.eval_suites | length > 0' "$_manifest" >/dev/null 2>&1; then
    _pp_prompt_contract_err "$_name: eval_suites must not be empty"
    return 1
  fi
  if ! _pp_prompt_contract_json_string "$_manifest" '.output_schema.format'; then
    _pp_prompt_contract_err "$_name: output_schema.format must be a non-empty string"
    return 1
  fi
  if ! _pp_prompt_contract_json_string "$_manifest" '.security_boundary.trusted_instructions'; then
    _pp_prompt_contract_err "$_name: security_boundary.trusted_instructions must be a non-empty string"
    return 1
  fi
  if ! _pp_prompt_contract_json_array "$_manifest" '.security_boundary.untrusted_inputs'; then
    _pp_prompt_contract_err "$_name: security_boundary.untrusted_inputs must be an array"
    return 1
  fi

  _bad_vars=$(jq -r '.input_variables[]? | select((test("^[A-Za-z_][A-Za-z0-9_]*$")) | not)' "$_manifest" 2>/dev/null)
  if [ -n "$_bad_vars" ]; then
    _pp_prompt_contract_err "$_name: invalid input variable(s): $(printf '%s' "$_bad_vars" | tr '\n' ' ')"
    return 1
  fi
  if ! jq -e '(.input_variables | length) == (.input_variables | unique | length)' "$_manifest" >/dev/null 2>&1; then
    _pp_prompt_contract_err "$_name: duplicate input_variables"
    return 1
  fi

  _actual=$(_pp_prompt_contract_placeholders "$_prompt")
  _declared=$(jq -r '.input_variables[]?' "$_manifest" 2>/dev/null | LC_ALL=C sort -u)
  if [ "$_actual" != "$_declared" ]; then
    _pp_prompt_contract_err "$_name: placeholder drift"
    _pp_prompt_contract_err "$_name: actual placeholders: $(printf '%s' "$_actual" | tr '\n' ' ')"
    _pp_prompt_contract_err "$_name: declared inputs: $(printf '%s' "$_declared" | tr '\n' ' ')"
    return 1
  fi

  _missing_eval=$(_pp_prompt_contract_list_eval_suites_missing "$_manifest")
  if [ -n "$_missing_eval" ]; then
    _pp_prompt_contract_err "$_name: eval_suites path(s) missing: $(printf '%s' "$_missing_eval" | tr '\n' ' ')"
    return 1
  fi

  [ "${PP_PROMPT_CONTRACT_QUIET:-0}" = "1" ] || printf '%s: OK\n' "$_name"
  return 0
}

pp_prompt_contract_lint() {
  local _target="${1:-}"
  local _quiet=0
  if [ "$_target" = "--quiet" ]; then
    _quiet=1
    shift
    _target="${1:-}"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    _pp_prompt_contract_err "jq is required"
    return 2
  fi

  local _old_quiet="${PP_PROMPT_CONTRACT_QUIET:-0}"
  [ "$_quiet" = "1" ] && PP_PROMPT_CONTRACT_QUIET=1

  local _ok=0 _fail=0 _name
  if [ -n "$_target" ]; then
    if pp_prompt_contract_lint_one "$_target"; then
      _ok=1
    else
      _fail=1
    fi
  else
    local _templates _manifests _missing_manifest
    _templates=$(_pp_prompt_contract_template_names)
    _manifests=$(_pp_prompt_contract_names)
    _missing_manifest=0
    while IFS= read -r _name; do
      [ -z "$_name" ] && continue
      if [ ! -f "$(_pp_prompt_contract_manifest_path "$_name")" ]; then
        _pp_prompt_contract_err "$_name: template has no manifest"
        _missing_manifest=$((_missing_manifest + 1))
      fi
    done <<EOF
$_templates
EOF
    while IFS= read -r _name; do
      [ -z "$_name" ] && continue
      if pp_prompt_contract_lint_one "$_name"; then
        _ok=$((_ok + 1))
      else
        _fail=$((_fail + 1))
      fi
    done <<EOF
$_manifests
EOF
    _fail=$((_fail + _missing_manifest))
  fi

  PP_PROMPT_CONTRACT_QUIET="$_old_quiet"
  export PP_PROMPT_CONTRACT_QUIET

  if [ "$_fail" -eq 0 ]; then
    [ "$_quiet" = "1" ] || printf 'prompt contracts: OK (%s/%s)\n' "$_ok" "$_ok"
    return 0
  fi
  [ "$_quiet" = "1" ] || printf 'prompt contracts: FAILED (%s ok, %s failed)\n' "$_ok" "$_fail"
  return 1
}

pp_prompt_contract_list() {
  if ! command -v jq >/dev/null 2>&1; then
    _pp_prompt_contract_err "jq is required"
    return 2
  fi
  printf 'ID\tVERSION\tOWNER\n'
  local _name _manifest
  while IFS= read -r _name; do
    [ -z "$_name" ] && continue
    _manifest=$(_pp_prompt_contract_manifest_path "$_name")
    jq -r '[.id, .version, .owner] | @tsv' "$_manifest" 2>/dev/null
  done <<EOF
$(_pp_prompt_contract_names)
EOF
}

pp_prompt_contract_versions_json() {
  # Compact prompt lineage map for telemetry/OAR rows. Fail open: callers use
  # this on hooks and statusline paths, so bad or missing manifests must not
  # block runtime behavior.
  if ! command -v jq >/dev/null 2>&1; then
    printf '{}\n'
    return 0
  fi
  local _dir
  _dir=$(_pp_prompt_contract_manifest_dir)
  if [ ! -d "$_dir" ]; then
    printf '{}\n'
    return 0
  fi
  find "$_dir" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null \
    | LC_ALL=C sort \
    | while IFS= read -r _manifest; do
        [ -z "$_manifest" ] && continue
        jq -c '
          select((.id | type == "string") and (.version | type == "string"))
          | {key: .id, value: .version}
        ' "$_manifest" 2>/dev/null
      done \
    | jq -sc 'from_entries' 2>/dev/null \
    || printf '{}\n'
}

pp_prompt_contract_show() {
  local _name="${1:-}"
  if [ -z "$_name" ]; then
    _pp_prompt_contract_err "show requires a prompt id"
    return 2
  fi
  local _manifest
  _manifest=$(_pp_prompt_contract_manifest_path "$_name")
  if [ ! -f "$_manifest" ]; then
    _pp_prompt_contract_err "$_name: manifest not found"
    return 1
  fi
  jq . "$_manifest"
}
