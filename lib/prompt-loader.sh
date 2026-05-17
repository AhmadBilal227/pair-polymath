#!/usr/bin/env bash
# Pair Polymath — prompt loader with shell-style ${var} substitution.
# Sourced by bin/statusline.sh. Requires PP_ROOT.
#
# Resolution: built-in prompts from $PP_ROOT/prompts/, user overrides from
# $PP_STATE_DIR/prompts/. User file wins if both exist.
#
# Substitution: ${var_name} placeholders are replaced with the value of the
# matching shell variable in the caller's environment, BUT only for names
# on the allowlist (PP_PROMPT_VAR_ALLOWLIST). Disallowed names render as
# empty string. Unknown vars also become empty strings (no fatal).

# Allowlist of substitutable placeholder names. Anything outside this set
# renders empty — this prevents a user-contributed prompt template (or a
# typo in a built-in) from referencing arbitrary env vars by name (e.g.
# ${OPENAI_API_KEY}). The indirect-lookup ${!_pp_key-} would resolve them
# otherwise; the single-pass-substitution guard only protects against
# re-scanning of LLM-returned VALUES, not against the ORIGINAL template
# directly naming a secret. (Ralph core round 1 — ai-engineer M8.)
# Default allowlist — overrideable via env (e.g. by tests). End-users with a
# customized template can extend this from config/default.env or user.env.
PP_PROMPT_VAR_ALLOWLIST="${PP_PROMPT_VAR_ALLOWLIST:-lens_group lens_focus lens_hats lens_system_prompt_addition lens_examples lens_silent_example relevance_directive grounded prev_observations recent_user_messages activity_tail transcript_filtered tool_summary signals_json transcript_tail_5 lens_registry PP_ROUTER_MIN PP_ROUTER_MAX file_contents git_status git_log git_diff_stat git_recent_files gh_prs gh_ci candidate_file inv_grep drop_reason rlens_group rlens_hats rlens_focus project_ctx recent_commits stories arxiv_titles cwd cwd_ls test_state recent_tools PP_LENS_COUNT MEMORY_BLOCK project_constraints}"
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
  local _pp_user_root="${PP_STATE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath}"
  local _pp_user_path="${_pp_user_root}/prompts/${_pp_name}.md"
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
  # inert. Allowlist-gated: any name not in PP_PROMPT_VAR_ALLOWLIST becomes
  # an empty string (defense against the ORIGINAL template naming a secret).
  local _pp_key _pp_value
  for _pp_key in $_pp_names; do
    # Allowlist check — disallowed names render empty
    case " $PP_PROMPT_VAR_ALLOWLIST " in
      *" $_pp_key "*)
        # Indirect lookup (bash 3.2-safe via ${!var})
        _pp_value="${!_pp_key-}"
        ;;
      *)
        _pp_value=""
        printf 'pp_render_prompt: placeholder ${%s} not in allowlist (rendered empty)\n' "$_pp_key" >&2
        ;;
    esac
    _pp_template="${_pp_template//\$\{$_pp_key\}/$_pp_value}"
  done

  # Sentinel-block stripping (F3, extended for I6): templates wrap optional
  # content in `<!-- <NAME>_BLOCK_START --> ... <!-- <NAME>_BLOCK_END -->`.
  # After substitution:
  #   - If the content between sentinels is empty/whitespace-only, delete
  #     the ENTIRE block including the sentinel lines AND the trailing
  #     newline after the END sentinel. This makes off-mode (empty body)
  #     render byte-identical to pre-stanza templates that never had the
  #     placeholder.
  #   - If non-empty, strip ONLY the two sentinel comment lines (and their
  #     own terminating newlines), leaving content in place.
  # Generic match on `<NAME>_BLOCK_START` / `<NAME>_BLOCK_END`, where NAME
  # is captured per-block. The state machine treats a START as a no-op
  # unless we eventually see a matching END.
  # awk state machine on lines so we don't depend on GNU sed -z.
  _pp_template=$(printf '%s' "$_pp_template" | LC_ALL=C awk '
    BEGIN { in_block = 0; buf = ""; nonblank = 0; block_name = "" }
    {
      if (match($0, /^[[:space:]]*<!--[[:space:]]*[A-Z_][A-Z_0-9]*_BLOCK_START[[:space:]]*-->[[:space:]]*$/)) {
        in_block = 1; buf = ""; nonblank = 0
        # extract the block name for END-matching
        n = $0
        sub(/^[[:space:]]*<!--[[:space:]]*/, "", n)
        sub(/_BLOCK_START[[:space:]]*-->.*$/, "", n)
        block_name = n
        next
      }
      if (in_block && match($0, /^[[:space:]]*<!--[[:space:]]*[A-Z_][A-Z_0-9]*_BLOCK_END[[:space:]]*-->[[:space:]]*$/)) {
        n = $0
        sub(/^[[:space:]]*<!--[[:space:]]*/, "", n)
        sub(/_BLOCK_END[[:space:]]*-->.*$/, "", n)
        if (n == block_name) {
          if (nonblank) {
            printf "%s", buf
          }
          in_block = 0; buf = ""; nonblank = 0; block_name = ""
          next
        }
      }
      if (in_block) {
        buf = buf $0 "\n"
        if ($0 ~ /[^[:space:]]/) nonblank = 1
      } else {
        print
      }
    }
  ')

  printf '%s' "$_pp_template"
}
