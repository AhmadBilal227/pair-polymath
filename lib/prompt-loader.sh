#!/usr/bin/env bash
# Pair Polymath — prompt loader with shell-style ${var} substitution.
# Sourced by bin/statusline.sh. Requires PP_ROOT.
#
# Resolution: built-in prompts from $PP_ROOT/prompts/, user overrides from
# $HOME/.claude/pair-polymath/prompts/. User file wins if both exist.
#
# Substitution: ${var_name} placeholders are replaced with the value of the
# matching shell variable in the caller's environment. Unknown vars become
# empty strings (no fatal).
#
# SECURITY (review fix H1): substitution is SINGLE-PASS over the set of
# placeholders found in the ORIGINAL template. Replacement values that
# happen to look like placeholders (e.g. a critique-LLM-supplied drop_reason
# of "${OPENAI_API_KEY}") are NEVER re-scanned, so they cannot exfiltrate
# environment secrets into the rendered prompt.

# pp_render_prompt NAME
# Stdout: rendered template (empty if not found).
# Returns 0 on success, 1 if neither built-in nor user version exists
# (with a "prompt not found" message on stderr).
pp_render_prompt() {
  # _pp_-prefixed locals avoid shadowing caller vars used in ${var} substitution.
  local _pp_name="${1:?pp_render_prompt requires a prompt name}"
  local _pp_user_path="${HOME}/.claude/pair-polymath/prompts/${_pp_name}.md"
  local _pp_builtin_path="${PP_ROOT}/prompts/${_pp_name}.md"
  local _pp_src=""

  if [ -f "$_pp_user_path" ]; then
    _pp_src="$_pp_user_path"
  elif [ -f "$_pp_builtin_path" ]; then
    _pp_src="$_pp_builtin_path"
  else
    printf 'pp_render_prompt: prompt not found: %s (looked in %s and %s)\n' \
      "$_pp_name" "$_pp_user_path" "$_pp_builtin_path" >&2
    return 1
  fi

  local _pp_template
  _pp_template=$(cat "$_pp_src")

  # Collect the UNIQUE placeholder names from the ORIGINAL template only.
  # We use bash regex (no pipeline) so pipefail/SIGPIPE in callers can't
  # affect us. After each match, advance past the full matched placeholder
  # so we always make progress (advancing past just `}` could infinite-loop
  # when an unrelated `}` precedes a real placeholder).
  local _pp_remaining="$_pp_template"
  local _pp_names=""
  local _pp_re='\$\{([A-Za-z_][A-Za-z0-9_]*)\}'
  while [[ "$_pp_remaining" =~ $_pp_re ]]; do
    local _pp_match_full="${BASH_REMATCH[0]}"  # "${foo}"
    local _pp_match_name="${BASH_REMATCH[1]}"  # "foo"
    case " $_pp_names " in
      *" $_pp_match_name "*) ;;                # already in set
      *) _pp_names="$_pp_names $_pp_match_name" ;;
    esac
    # Advance past the entire matched placeholder
    _pp_remaining="${_pp_remaining#*"$_pp_match_full"}"
  done

  # SINGLE-PASS substitution: walk the original-placeholder set, do one
  # template-wide replacement per name. The replacement value is treated as
  # an opaque literal — we never rescan, so secrets disguised as ${X} stay
  # inert.
  local _pp_key _pp_value
  for _pp_key in $_pp_names; do
    # Indirect lookup (bash 3.2-safe via ${!var})
    _pp_value="${!_pp_key-}"
    _pp_template="${_pp_template//\$\{$_pp_key\}/$_pp_value}"
  done

  printf '%s' "$_pp_template"
}
