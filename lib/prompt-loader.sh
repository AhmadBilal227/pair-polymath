#!/usr/bin/env bash
# Pair Polymath — prompt loader with shell-style ${var} substitution.
# Sourced by bin/statusline.sh. Requires PP_ROOT.
#
# Resolution: built-in prompts from $PP_ROOT/prompts/, user overrides from
# $HOME/.claude/pair-polymath/prompts/. User file wins if both exist.
#
# Substitution: ${var_name} placeholders are replaced with the value of the
# matching shell variable in the caller's environment. Unknown vars become
# empty strings (no fatal). No nested expressions, no defaults syntax.

# pp_render_prompt NAME
# Reads prompts/${NAME}.md (user override first, then built-in), substitutes
# ${var} placeholders against the caller's exported/local-in-scope vars,
# prints to stdout. Returns 0 on success, 1 if neither built-in nor user
# version exists.
pp_render_prompt() {
  # NOTE: locals are prefixed _pp_ to avoid shadowing caller variables with the
  # same name (template ${var} substitution does indirect lookup against the
  # caller's environment — a bare `local name` here would clobber a caller's
  # ${name} placeholder).
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

  # Read the template, substitute ${var} placeholders.
  local _pp_template
  _pp_template=$(cat "$_pp_src")

  # Iteratively replace each ${var} with the caller's value. We accept names
  # of [A-Za-z_][A-Za-z0-9_]*. Loop until no placeholder remains (or a fixed
  # iteration count, to avoid runaway from value-contains-placeholder loops).
  local _pp_i=0
  while [ "$_pp_i" -lt 50 ]; do
    # Extract the next placeholder, if any.
    local _pp_var
    _pp_var=$(printf '%s' "$_pp_template" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | head -1)
    [ -z "$_pp_var" ] && break
    # Strip ${} → bare name
    local _pp_key="${_pp_var#\$\{}"
    _pp_key="${_pp_key%\}}"
    # Look up via indirect expansion (bash 3.2-safe)
    local _pp_value=""
    eval "_pp_value=\"\${$_pp_key:-}\""
    # Replace ALL occurrences in this pass. Use bash parameter expansion (3.2-safe).
    _pp_template="${_pp_template//$_pp_var/$_pp_value}"
    _pp_i=$((_pp_i + 1))
  done

  printf '%s' "$_pp_template"
}
