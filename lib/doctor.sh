#!/usr/bin/env bash
# Pair Polymath — health-check helpers. Sourced by bin/polymath.
# Each check function returns:
#   0 = green (printed with ✓)
#   1 = yellow (printed with ⚠) — degraded but functional
#   2 = red (printed with ✗) — broken; doctor exits non-zero overall
# Each check prints exactly ONE line to stdout: "<icon> <label> — <detail>"

# Color helpers — only emit ANSI if stdout is a TTY
_pp_doctor_init_colors() {
  if [ -t 1 ]; then
    _DC_GREEN=$'\033[32m'
    _DC_YELLOW=$'\033[33m'
    _DC_RED=$'\033[31m'
    _DC_DIM=$'\033[2m'
    _DC_RESET=$'\033[0m'
  else
    _DC_GREEN=""; _DC_YELLOW=""; _DC_RED=""; _DC_DIM=""; _DC_RESET=""
  fi
}

_pp_doctor_green()  { printf '  %s✓%s %s%s\n' "$_DC_GREEN"  "$_DC_RESET" "$1" "${2:+ — $2}"; }
_pp_doctor_yellow() { printf '  %s⚠%s %s%s\n' "$_DC_YELLOW" "$_DC_RESET" "$1" "${2:+ — $2}"; }
_pp_doctor_red()    { printf '  %s✗%s %s%s\n' "$_DC_RED"    "$_DC_RESET" "$1" "${2:+ — $2}"; }

# === Individual checks ===

doctor_check_bash() {
  # Enforce >= 3.2 (the macOS-default floor we ship against). Bash 3.0/3.1
  # would otherwise sneak through a major-only check (review fix L1).
  local major="${BASH_VERSINFO[0]:-0}"
  local minor="${BASH_VERSINFO[1]:-0}"
  if [ "$major" -ge 4 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 2 ]; }; then
    _pp_doctor_green "bash" "$BASH_VERSION"
    return 0
  fi
  _pp_doctor_red "bash" "version $BASH_VERSION too old (need >=3.2)"
  return 2
}

doctor_check_jq() {
  if command -v jq >/dev/null 2>&1; then
    local v
    v=$(jq --version 2>/dev/null)
    _pp_doctor_green "jq" "$v"
    return 0
  fi
  _pp_doctor_red "jq" "not installed; install via brew/apt-get and re-run installer"
  return 2
}

doctor_check_llm() {
  if ! command -v llm >/dev/null 2>&1; then
    _pp_doctor_red "llm" "not on PATH; if pip3-installed, add \$HOME/.local/bin to PATH"
    return 2
  fi
  local v
  v=$(llm --version 2>/dev/null | head -1)
  _pp_doctor_green "llm" "$v"
  return 0
}

doctor_check_openai_key() {
  if ! command -v llm >/dev/null 2>&1; then
    _pp_doctor_yellow "openai key" "skipped (llm not on PATH)"
    return 1
  fi
  if llm keys list 2>/dev/null | grep -q '^openai$'; then
    _pp_doctor_green "openai key" "configured"
    return 0
  fi
  _pp_doctor_red "openai key" "not set; run: llm keys set openai"
  return 2
}

doctor_check_settings_json() {
  local settings="${CLAUDE_DIR:-$HOME/.claude}/settings.json"
  if [ ! -f "$settings" ]; then
    _pp_doctor_red "settings.json" "not found at $settings; run ./bin/install.sh"
    return 2
  fi
  if ! jq empty "$settings" 2>/dev/null; then
    _pp_doctor_red "settings.json" "invalid JSON at $settings"
    return 2
  fi
  _pp_doctor_green "settings.json" "valid"
  return 0
}

# Extract a filesystem path from a settings.json command string like
#   "bash '/path with spaces/bin/statusline.sh'"
#   "bash /Users/x/bin/statusline.sh"
#   "/Users/x/hooks/inject-monitor-insight.sh"
# Echoes the path; returns 0 if extraction succeeded.
_pp_doctor_extract_path() {
  local cmd="$1"
  # Strip a leading "bash " or "/usr/bin/env bash " etc.
  cmd="${cmd#bash }"
  cmd="${cmd#/usr/bin/env bash }"
  # Strip surrounding single quotes if present
  case "$cmd" in
    \'*\') cmd="${cmd#\'}"; cmd="${cmd%\'}" ;;
  esac
  # Strip surrounding double quotes if present
  case "$cmd" in
    \"*\") cmd="${cmd#\"}"; cmd="${cmd%\"}" ;;
  esac
  # Take only the first argument (path may have spaces if quoted; if unquoted,
  # we can't recover spaces — accept the caller's risk).
  printf '%s' "$cmd"
}

doctor_check_statusline_wired() {
  local settings="${CLAUDE_DIR:-$HOME/.claude}/settings.json"
  [ -f "$settings" ] || { _pp_doctor_yellow "statusLine wired" "skipped (no settings.json)"; return 1; }
  local cmd
  cmd=$(jq -r '.statusLine?.command // ""' "$settings" 2>/dev/null)
  if [ -z "$cmd" ]; then
    _pp_doctor_yellow "statusLine wired" "no statusLine in settings.json"
    return 1
  fi

  # Strict-match: resolve both paths and compare. Substring match (the previous
  # implementation) would false-pass a /tmp/statusline.sh decoy (review fix H2).
  # The yellow branch now returns 1 so the summary counts honestly (review fix H1).
  local extracted want_real got_real
  extracted=$(_pp_doctor_extract_path "$cmd")
  want_real=$(cd "$PP_ROOT" 2>/dev/null && realpath "bin/statusline.sh" 2>/dev/null)
  got_real=$(realpath "$extracted" 2>/dev/null)

  if [ -n "$want_real" ] && [ "$got_real" = "$want_real" ]; then
    _pp_doctor_green "statusLine wired" "→ $extracted"
    return 0
  fi
  _pp_doctor_yellow "statusLine wired" "points to a different script: $extracted"
  return 1
}

# v0.5.5: subagentStatusLine wires the ⚛ brand on polymath-spawned subagent
# rows. Yellow (not red) when missing — pre-v0.5.5 installs simply don't
# brand subagent rows, which is a cosmetic regression, not a correctness one.
doctor_check_subagent_statusline_wired() {
  local settings="${CLAUDE_DIR:-$HOME/.claude}/settings.json"
  [ -f "$settings" ] || { _pp_doctor_yellow "subagentStatusLine wired" "skipped (no settings.json)"; return 1; }
  local cmd
  cmd=$(jq -r '.subagentStatusLine?.command // ""' "$settings" 2>/dev/null)
  if [ -z "$cmd" ]; then
    _pp_doctor_yellow "subagentStatusLine wired" "not set (pre-v0.5.5 install; re-run installer to enable brand glyph on subagent rows)"
    return 1
  fi
  local extracted want_real got_real
  extracted=$(_pp_doctor_extract_path "$cmd")
  want_real=$(cd "$PP_ROOT" 2>/dev/null && realpath "hooks/subagent-statusline.sh" 2>/dev/null)
  got_real=$(realpath "$extracted" 2>/dev/null)
  if [ -n "$want_real" ] && [ "$got_real" = "$want_real" ]; then
    _pp_doctor_green "subagentStatusLine wired" "→ $extracted"
    return 0
  fi
  _pp_doctor_yellow "subagentStatusLine wired" "points to a different script: $extracted"
  return 1
}

# v0.5.3: DIM gate progress
doctor_check_dim_gate_progress() {
  if ! [ -r "$PP_ROOT/lib/dim.sh" ]; then
    _pp_doctor_yellow "DIM gate progress" "lib/dim.sh missing (pre-v0.5.3 install)"
    return 1
  fi
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim.sh" 2>/dev/null || {
    _pp_doctor_red "DIM gate progress" "lib/dim.sh failed to source"
    return 2
  }
  local sha8="${PP_DIM_PROJECT_SHA8:-}"
  if [ -z "$sha8" ] && [ -r "$PP_ROOT/lib/project-identity.sh" ]; then
    # shellcheck disable=SC1091
    . "$PP_ROOT/lib/project-identity.sh" 2>/dev/null || true
    type pp_project_root_sha8 >/dev/null 2>&1 && \
      sha8=$(pp_project_root_sha8 2>/dev/null || true)
  fi
  [ -z "$sha8" ] && sha8="default"
  local state
  state=$(pp_dim_get_current_state "$sha8")
  case "$state" in
    active)
      _pp_doctor_green "DIM gate progress" "active (gate cleared, holdout validated)"
      return 0
      ;;
    quarantine)
      _pp_doctor_red "DIM gate progress" "quarantine (post-activation drift detected; will auto-recover after 14d clean window)"
      return 2
      ;;
    monitoring|gated)
      _pp_doctor_yellow "DIM gate progress" "$state (gate not yet cleared; passively accumulating OAR data)"
      return 1
      ;;
    *)
      _pp_doctor_yellow "DIM gate progress" "unknown state: $state"
      return 1
      ;;
  esac
}

doctor_check_hooks_wired() {
  local settings="${CLAUDE_DIR:-$HOME/.claude}/settings.json"
  [ -f "$settings" ] || { _pp_doctor_yellow "hooks wired" "skipped"; return 1; }

  # Strict-match: hook command must resolve to OUR script under $PP_ROOT/hooks/,
  # not just any file with that basename (review fix H2).
  local want_user want_post want_session
  want_user=$(cd "$PP_ROOT" 2>/dev/null && realpath "hooks/inject-monitor-insight.sh" 2>/dev/null)
  want_post=$(cd "$PP_ROOT" 2>/dev/null && realpath "hooks/cache-test-result.sh" 2>/dev/null)
  want_session=$(cd "$PP_ROOT" 2>/dev/null && realpath "hooks/session-end.sh" 2>/dev/null)

  local user_match=0 post_match=0 session_match=0
  local cmd extracted resolved
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    extracted=$(_pp_doctor_extract_path "$cmd")
    resolved=$(realpath "$extracted" 2>/dev/null)
    [ -n "$want_user" ] && [ "$resolved" = "$want_user" ] && user_match=1
  done < <(jq -r '.hooks?.UserPromptSubmit[]?.hooks[]?.command // empty' "$settings" 2>/dev/null)

  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    extracted=$(_pp_doctor_extract_path "$cmd")
    resolved=$(realpath "$extracted" 2>/dev/null)
    [ -n "$want_post" ] && [ "$resolved" = "$want_post" ] && post_match=1
  done < <(jq -r '.hooks?.PostToolUse[]?.hooks[]?.command // empty' "$settings" 2>/dev/null)

  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    extracted=$(_pp_doctor_extract_path "$cmd")
    resolved=$(realpath "$extracted" 2>/dev/null)
    [ -n "$want_session" ] && [ "$resolved" = "$want_session" ] && session_match=1
  done < <(jq -r '.hooks?.SessionEnd[]?.hooks[]?.command // empty' "$settings" 2>/dev/null)

  if [ "$user_match" -eq 1 ] && [ "$post_match" -eq 1 ] && [ "$session_match" -eq 1 ]; then
    _pp_doctor_green "hooks wired" "UserPromptSubmit + PostToolUse + SessionEnd → \$PP_ROOT/hooks"
    return 0
  fi
  if [ "$user_match" -eq 1 ] && [ "$post_match" -eq 1 ] && [ "$session_match" -eq 0 ] \
      && [ "${PP_OAR_ENABLE:-0}" != "1" ]; then
    _pp_doctor_yellow "hooks wired" "SessionEnd missing; OAR disabled, but re-run installer before enabling OAR"
    return 1
  fi
  _pp_doctor_red "hooks wired" "missing or pointing elsewhere (UserPromptSubmit=$user_match PostToolUse=$post_match SessionEnd=$session_match); re-run installer"
  return 2
}

doctor_check_cache_writable() {
  local d="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
  mkdir -p "$d" 2>/dev/null
  if [ -w "$d" ]; then
    _pp_doctor_green "cache dir writable" "$d"
    return 0
  fi
  _pp_doctor_red "cache dir writable" "$d is not writable"
  return 2
}

doctor_check_budget_file() {
  local f
  f="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/pp-budget-$(date +%Y%m%d).txt"
  if [ ! -f "$f" ]; then
    _pp_doctor_yellow "budget tracker" "no entry yet today (will be created on first cycle)"
    return 1
  fi
  local n
  n=$(cat "$f" 2>/dev/null)
  if [ "${n:-x}" = "x" ] || ! [ "$n" -eq "$n" ] 2>/dev/null; then
    _pp_doctor_red "budget tracker" "unreadable or non-numeric ($f)"
    return 2
  fi
  _pp_doctor_green "budget tracker" "$n calls today"
  return 0
}

doctor_check_lenses() {
  # PP_ROOT should already be set by the caller (bin/polymath)
  if ! type pp_load_lenses >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$PP_ROOT/lib/lens-loader.sh"
  fi
  if pp_load_lenses 2>/dev/null; then
    _pp_doctor_green "lenses" "$PP_LENS_COUNT loaded"
    return 0
  fi
  _pp_doctor_red "lenses" "registry empty (check $PP_ROOT/lenses/)"
  return 2
}

doctor_check_prompts() {
  local expected="planner analyst-primary analyst-retry critique escalation-investigation tip-digest router pattern-extraction eviction-summary"
  local missing=""
  local p
  for p in $expected; do
    [ -f "$PP_ROOT/prompts/$p.md" ] || missing="$missing $p"
  done
  if [ -z "$missing" ]; then
    _pp_doctor_green "prompts" "9/9 built-in present"
    return 0
  fi
  _pp_doctor_red "prompts" "missing:$missing"
  return 2
}

doctor_check_prompt_contracts() {
  if [ ! -r "$PP_ROOT/lib/prompt-contract.sh" ]; then
    _pp_doctor_red "prompt contracts" "lib/prompt-contract.sh missing"
    return 2
  fi
  if ! (
    # shellcheck disable=SC1091
    . "$PP_ROOT/lib/prompt-contract.sh" 2>/dev/null
    PP_PROMPT_CONTRACT_QUIET=1 pp_prompt_contract_lint --quiet
  ) >/dev/null 2>&1; then
    _pp_doctor_red "prompt contracts" "lint failed; run: polymath prompts lint"
    return 2
  fi
  _pp_doctor_green "prompt contracts" "9/9 manifests lint clean"
  return 0
}

doctor_check_transcript_libs() {
  # v0.4 Phase 1 — verify lib/transcript.sh + lib/tool-summary.sh load, that
  # jq can parse a synthetic JSONL, that pairing by tool_use.id works, AND
  # that the canonical redactor pp_memory_redact_body is actually reached
  # (not the 4-pattern fallback). The redaction probe is the load-bearing
  # part — without it, doctor was unable to catch the v0.4 'phantom
  # pp_redact_secrets' regression that the 4-way ralph review found.
  if [ ! -r "$PP_ROOT/lib/transcript.sh" ] || [ ! -r "$PP_ROOT/lib/tool-summary.sh" ]; then
    _pp_doctor_red "transcript libs" "lib files missing"
    return 2
  fi
  local _probe
  _probe=$( \
    . "$PP_ROOT/lib/transcript.sh" 2>/dev/null && \
    . "$PP_ROOT/lib/tool-summary.sh" 2>/dev/null && \
    type pp_transcript_filter >/dev/null 2>&1 && \
    type pp_tool_summary_render >/dev/null 2>&1 && \
    {
      _t=$(mktemp) || exit 99
      printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_probe","name":"Read","input":{"file_path":"/probe.ts"}}]}}' > "$_t"
      printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_probe","content":[{"type":"text","text":"ok pair found"}]}]}}' >> "$_t"
      _json=$(pp_transcript_tool_calls "$_t")
      rm -f "$_t"
      printf '%s' "$_json" | jq -e '.[0].id == "tu_probe" and (.[0].summary | contains("ok pair"))' >/dev/null 2>&1 || exit 2
      # Canonical-redactor probe: send a Bearer token + email through filter;
      # only pp_memory_redact_body (11-pattern) handles those — the awk
      # fallback misses both.
      _t2=$(mktemp) || exit 99
      printf '%s\n' '{"type":"user","message":{"role":"user","content":"key Bearer abcdef12345678901234567890XYZ for alice@example.com"}}' > "$_t2"
      _filtered=$(pp_transcript_filter "$_t2")
      rm -f "$_t2"
      printf '%s' "$_filtered" | grep -q 'REDACTED-BEARER' || exit 3
      printf '%s' "$_filtered" | grep -q 'REDACTED-EMAIL' || exit 4
      printf 'ok'
    }
  )
  case "$_probe" in
    ok) _pp_doctor_green "transcript libs" "filter+tool_calls+canonical-redactor wired"
        return 0 ;;
    *) _pp_doctor_red "transcript libs" "probe failed (canonical redactor not wired or jq pairing broken)"
       return 2 ;;
  esac
}

doctor_check_router_libs() {
  # v0.4 Phase 2.5 Track 1.2 — verify the router meta-lens stack is
  # wired correctly. Three integration probes:
  #   (a) lib/router-signals.sh + lib/router.sh source cleanly
  #   (b) prompts/router.md placeholders substitute via pp_render_prompt
  #       (catches the v0.4 Phase 2 allowlist-gap class of regression)
  #   (c) pp_router_pick_lenses returns the forced ID under FORCE_OUTPUT
  #       (catches the case-handling / regex / membership-check class)
  if [ ! -r "$PP_ROOT/lib/router.sh" ] || [ ! -r "$PP_ROOT/lib/router-signals.sh" ]; then
    _pp_doctor_red "router libs" "lib files missing"
    return 2
  fi
  local _probe
  _probe=$( \
    . "$PP_ROOT/lib/prompt-loader.sh" 2>/dev/null && \
    . "$PP_ROOT/lib/router-signals.sh" 2>/dev/null && \
    . "$PP_ROOT/lib/router.sh" 2>/dev/null && \
    type pp_router_pick_lenses >/dev/null 2>&1 && \
    type pp_router_extract_signals >/dev/null 2>&1 && \
    {
      # Probe (b): render the prompt with synthetic placeholders.
      _signals='{"phase":"debugging","outcome":"test_failed","confidence":"medium","tone":"neutral","session_age_min":5,"budget_remaining_pct":90,"last_test_failed":true,"recent_edit_density":2}'
      _rendered=$(
        signals_json="$_signals" \
        transcript_tail_5="probe" \
        lens_registry="ENGINEERING"$'\n'"SECURITY" \
        PP_ROUTER_MIN=1 PP_ROUTER_MAX=2 \
        pp_render_prompt router 2>/dev/null
      )
      # Substitution worked → signals JSON appears in rendered prompt.
      printf '%s' "$_rendered" | grep -qF 'debugging' || exit 2
      printf '%s' "$_rendered" | grep -qF 'ENGINEERING' || exit 3
      # Probe (c): forced-output round-trips real UPPERCASE_UNDERSCORE ID.
      PP_LENS_IDS_AVAILABLE="ENGINEERING"$'\n'"SECURITY"
      PP_ROUTER_FORCE_OUTPUT="ENGINEERING"
      export PP_LENS_IDS_AVAILABLE PP_ROUTER_FORCE_OUTPUT
      _picked=$(pp_router_pick_lenses "$_signals" "probe")
      unset PP_LENS_IDS_AVAILABLE PP_ROUTER_FORCE_OUTPUT
      printf '%s' "$_picked" | grep -qxF 'ENGINEERING' || exit 4
      printf 'ok'
    }
  )
  case "$_probe" in
    ok) _pp_doctor_green "router libs" "pick + render + ID round-trip verified"
        return 0 ;;
    *) _pp_doctor_red "router libs" "probe failed (allowlist or case-handling regression)"
       return 2 ;;
  esac
}

doctor_check_coreutils() {
  # v0.4 Phase 2.5 Track 1.2 — coreutils provides timeout/gtimeout,
  # used by the router LLM call's primary path. Without them the
  # router falls back to a bounded-wait subshell that works but is
  # less robust. INFO-level (yellow, not red).
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    _pp_doctor_green "coreutils" "timeout binary present"
    return 0
  fi
  case "$(uname -s)" in
    Darwin)
      _pp_doctor_yellow "coreutils" "absent; recommend: brew install coreutils"
      ;;
    *)
      _pp_doctor_yellow "coreutils" "absent; install via apt/yum/apk"
      ;;
  esac
  return 1
}

doctor_check_budget_pressure() {
  # v0.4.1 Task 5 — surface daily-budget pressure proactively in doctor.
  # Green below PP_BUDGET_WARN_PCT used (default 80%).
  # Yellow at PP_BUDGET_WARN_PCT-PP_BUDGET_RED_PCT (80-95%).
  # Red at PP_BUDGET_RED_PCT+ (95%+): cycles will skip.
  # Same thresholds as the line-1 pip + idle fallback — single source.
  # (GPT plan-review C1: unified envs across all surfaces.)
  if ! type pp_budget_remaining_pct >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$PP_ROOT/lib/budget.sh" 2>/dev/null || true
  fi
  if ! type pp_budget_remaining_pct >/dev/null 2>&1; then
    # v0.4.1 review-fix (I4, GPT #7): a missing budget helper is a broken
    # install, not a degraded state. Red so the user re-runs install.sh
    # instead of silently flying blind on budget pressure.
    _pp_doctor_red "budget pressure" "lib/budget.sh pp_budget_remaining_pct helper unavailable — broken install; re-run install.sh"
    return 2
  fi
  local _pct _used _warn _red
  _pct=$(pp_budget_remaining_pct 2>/dev/null)
  case "$_pct" in ''|*[!0-9]*) _pct=100 ;; esac
  _used=$(( 100 - _pct ))
  _warn="${PP_BUDGET_WARN_PCT:-80}"
  _red="${PP_BUDGET_RED_PCT:-95}"
  case "$_warn" in ''|*[!0-9]*) _warn=80 ;; esac
  case "$_red"  in ''|*[!0-9]*) _red=95  ;; esac
  # v0.4.1 review-fix (I2): lower-bound clamp. WARN/RED=0 → permanent red.
  [ "$_warn" -lt 1 ] && _warn=80
  [ "$_red"  -lt 1 ] && _red=95
  # v0.4.1 review-fix (I1, all-three-reviewers): detect inverted thresholds
  # and surface as yellow — the amber zone vanishes silently otherwise.
  if [ "$_warn" -ge "$_red" ]; then
    _pp_doctor_yellow "budget pressure" "PP_BUDGET_WARN_PCT (${_warn}) >= PP_BUDGET_RED_PCT (${_red}) — amber zone disabled; fix in user.env"
    return 1
  fi
  if [ "$_used" -ge "$_red" ]; then
    _pp_doctor_red "budget pressure" "${_pct}% remaining; cycles will skip — raise PP_MAX_DAILY_CALLS or wait for midnight reset"
    return 2
  elif [ "$_used" -ge "$_warn" ]; then
    _pp_doctor_yellow "budget pressure" "${_pct}% remaining (${_used}% used); raise PP_MAX_DAILY_CALLS if cycles pause"
    return 1
  fi
  _pp_doctor_green "budget pressure" "${_pct}% remaining"
  return 0
}

doctor_check_cache_permissions() {
  # v0.4.2 check #17 — surface lax-mode cache files. Cache contents include
  # code excerpts, file paths, and whatever the LLM echoed back; these must
  # be owner-only (0600 files / 0700 dir) on multi-user systems. Older
  # installs created files at 0644 via the default umask 022. The fix is one
  # command: `polymath cache clear`.
  # Review G1: route through pp_file_mode (GNU `-c %a` + BSD `-f %Lp`) so
  # the check actually runs on Linux. Review G11: collect both findings
  # before returning so a mixed misconfig (loose dir + loose files) shows
  # both reasons in one diagnostic.
  if ! type pp_file_mode >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$PP_ROOT/lib/grounding.sh" 2>/dev/null || true
  fi
  local _cdir="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
  if [ ! -d "$_cdir" ]; then
    _pp_doctor_green "cache permissions" "no cache dir yet"
    return 0
  fi
  local _dir_mode _loose
  _dir_mode=$(pp_file_mode "$_cdir")
  _loose=$(find "$_cdir" -maxdepth 1 -type f ! -perm 600 2>/dev/null | wc -l | tr -d ' ')
  local _problems=""
  if [ -n "$_dir_mode" ] && [ "$_dir_mode" != "700" ]; then
    _problems="dir mode is ${_dir_mode} (want 700)"
  fi
  if [ "$_loose" -gt 0 ]; then
    [ -n "$_problems" ] && _problems="${_problems}; "
    _problems="${_problems}${_loose} file(s) mode != 600"
  fi
  if [ -n "$_problems" ]; then
    _pp_doctor_yellow "cache permissions" "${_problems}; run: polymath cache clear (or chmod 700 ${_cdir})"
    return 1
  fi
  _pp_doctor_green "cache permissions" "dir 700, files 600"
  return 0
}

doctor_check_dismiss_libs() {
  # v0.5 Phase 3 check #18 — verify lib/dismiss.sh sources cleanly + all
  # required functions are defined + JSONL is well-formed if present.
  if ! (
    # shellcheck disable=SC1091
    . "$PP_ROOT/lib/dismiss.sh" 2>/dev/null
    type pp_dismiss_add pp_dismiss_list pp_dismiss_render pp_dismiss_is_suppressed pp_dismiss_auto_suppress >/dev/null 2>&1
  ); then
    _pp_doctor_red "dismiss libs" "lib/dismiss.sh failed to source or missing functions; re-install"
    return 2
  fi
  # If a JSONL exists, validate each line parses.
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dismiss.sh" 2>/dev/null
  local _file
  _file=$(pp_dismiss_file_path 2>/dev/null) || true
  if [ -n "$_file" ] && [ -f "$_file" ]; then
    if ! jq -c . "$_file" >/dev/null 2>&1; then
      _pp_doctor_yellow "dismiss libs" "malformed JSONL at $_file; some rules will be ignored"
      return 1
    fi
  fi
  _pp_doctor_green "dismiss libs" "lib/dismiss.sh OK; JSONL well-formed"
  return 0
}

doctor_check_retry_router_health() {
  # v0.5.1 check #19 — retry router health.
  # Green when: disabled (default) OR active without rollback flag.
  # Red when: auto-rollback flag currently active.
  if [ "${PP_RETRY_ROUTER_ENABLE:-0}" != "1" ] && [ "${PP_RETRY_ROUTER_SHADOW:-0}" != "1" ]; then
    _pp_doctor_green "retry router" "disabled (default)"
    return 0
  fi
  if [ -z "${_pp_rollback_sourced:-}" ]; then
    # shellcheck disable=SC1091
    . "$PP_ROOT/lib/auto-rollback.sh" 2>/dev/null && _pp_rollback_sourced=1
  fi
  if pp_rollback_is_active 2>/dev/null; then
    _pp_doctor_red "retry router" "auto-rollback ACTIVE; review: polymath retry-router status"
    return 2
  fi
  _pp_doctor_green "retry router" "active, no SLO breach"
  return 0
}

doctor_check_install_drift() {
  # v0.5.1.1 check #20 — install drift detection.
  #
  # Two failure modes survive an operator who installed once-and-never-cleaned:
  # (a) A legacy global hook file at ~/.claude/hooks/inject-monitor-insight.sh
  #     persists after the v0.4+ install path moved to ${PP_ROOT}/hooks/. It's
  #     not necessarily wired (settings.json points at the new path), but the
  #     stale file is dead code that may confuse operator triage.
  # (b) Legacy cc-monitor-*-lens[0-9]-* cache files from the pre-v0.4 indexed
  #     scheme. The v0.4+ codebase keys caches by lens ID (cc-monitor-${sid}-
  #     ${LENS_ID}.txt), not numeric index. Old indexed files are orphaned but
  #     never reaped — they bloat ~/.claude/cache.
  #
  # Yellow on either (cosmetic, not functional). Green on neither.
  local _legacy_hook="${HOME}/.claude/hooks/inject-monitor-insight.sh"
  local _cache_dir="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
  local _findings=""

  if [ -f "$_legacy_hook" ]; then
    _findings="legacy global hook at ~/.claude/hooks/inject-monitor-insight.sh"
  fi

  # Indexed-lens cache files (pre-v0.4 format). [ -d ] guard prevents find
  # error noise on fresh installs where cache dir hasn't been created yet.
  if [ -d "$_cache_dir" ]; then
    local _indexed
    _indexed=$(find "$_cache_dir" -maxdepth 1 -type f -name 'cc-monitor-*-lens[0-9]*' 2>/dev/null | head -1)
    if [ -n "$_indexed" ]; then
      if [ -n "$_findings" ]; then
        _findings="$_findings; pre-v0.4 indexed-lens cache files"
      else
        _findings="pre-v0.4 indexed-lens cache files"
      fi
    fi
  fi

  if [ -z "$_findings" ]; then
    _pp_doctor_green "install drift" "no stale hooks or pre-v0.4 cache files"
    return 0
  fi

  _pp_doctor_yellow "install drift" "$_findings; rm when convenient"
  return 1
}

doctor_check_oar_quality() {
  # v0.5.2 check #21 — OAR data-quality sentinel (PM3 in plan addendum).
  #
  # The pre-mortem scenario: pp_oar_referenced is silently broken
  # (e.g. schema mismatch never wired end-to-end) so every labeled row lands
  # on "ignored." Doctor check #20 (install drift) and stuck-row signals stay
  # green because the labeler COMPLETES — it just always lands on the same
  # degenerate outcome. This check is the sentinel for that pattern.
  #
  # Returns:
  #   0 = green (disabled, no data, insufficient sample, or non-degenerate)
  #   1 = yellow (>=20 rows AND 100% ignored — likely silent failure)
  #
  # Threshold rationale: 20 rows balances (a) catching the bug within 1-2
  # sessions of real use with (b) tolerating a quiet warmup where the first
  # handful of advisories legitimately happened to be ignored.
  if [ "${PP_OAR_ENABLE:-0}" != "1" ]; then
    _pp_doctor_green "OAR quality" "OAR disabled"
    return 0
  fi

  local _cache_dir="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
  local _labeled="${_cache_dir}/oar-labeled.jsonl"
  local _pending="${_cache_dir}/oar-pending.jsonl"
  local _injected_count _pending_rows _labeled_rows
  _injected_count=$(find "$_cache_dir" -maxdepth 1 -type f -name 'cc-monitor-injected-hash-*' 2>/dev/null | wc -l | tr -d ' ')
  _pending_rows=0
  [ -f "$_pending" ] && _pending_rows=$(wc -l < "$_pending" 2>/dev/null | tr -d ' ')
  _labeled_rows=0
  [ -f "$_labeled" ] && _labeled_rows=$(wc -l < "$_labeled" 2>/dev/null | tr -d ' ')
  case "$_injected_count" in ''|*[!0-9]*) _injected_count=0 ;; esac
  case "$_pending_rows" in ''|*[!0-9]*) _pending_rows=0 ;; esac
  case "$_labeled_rows" in ''|*[!0-9]*) _labeled_rows=0 ;; esac

  if command -v jq >/dev/null 2>&1; then
    if ! command -v pp_project_id >/dev/null 2>&1; then
      # shellcheck source=project-identity.sh
      . "${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}/lib/project-identity.sh" 2>/dev/null || true
    fi
    local _project_id _identity_counts _missing_identity _foreign_identity
    _project_id=""
    if command -v pp_project_id >/dev/null 2>&1; then
      _project_id=$(pp_project_id "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || printf '')
    fi
    if [ -n "$_project_id" ] && [ -s "$_pending" ]; then
      _identity_counts=$(jq -R 'fromjson?' "$_pending" 2>/dev/null \
        | jq -s -r --arg project_id "$_project_id" '
            map(select(type == "object")) as $rows
            | ($rows | map(select((.project_id // "") == "")) | length) as $missing
            | ($rows | map(select((.project_id // "") != "" and .project_id != $project_id)) | length) as $foreign
            | "\($missing)\t\($foreign)"
          ' 2>/dev/null)
      _missing_identity=$(printf '%s' "$_identity_counts" | cut -f1)
      _foreign_identity=$(printf '%s' "$_identity_counts" | cut -f2)
      case "$_missing_identity" in ''|*[!0-9]*) _missing_identity=0 ;; esac
      case "$_foreign_identity" in ''|*[!0-9]*) _foreign_identity=0 ;; esac
      if [ "$_missing_identity" -gt 0 ] || [ "$_foreign_identity" -gt 0 ]; then
        _pp_doctor_yellow "OAR quality" "pending project identity drift: ${_missing_identity} rows missing identity, ${_foreign_identity} rows from another project; history defaults to current project"
        return 1
      fi
    fi
  fi

  if [ "$_injected_count" -gt 0 ] && [ "$_pending_rows" -eq 0 ] && [ "$_labeled_rows" -lt "$_injected_count" ]; then
    _pp_doctor_yellow "OAR quality" "appears starved: ${_injected_count} injected observations, ${_pending_rows} pending rows, ${_labeled_rows} labeled rows — verify SessionEnd hook wiring"
    return 1
  fi

  if [ ! -f "$_labeled" ]; then
    _pp_doctor_green "OAR quality" "no labeled data yet"
    return 0
  fi

  # Cheap raw-line count first — skip the jq fork below threshold.
  local _raw
  _raw=$(wc -l < "$_labeled" 2>/dev/null | tr -d ' ')
  case "$_raw" in ''|*[!0-9]*) _raw=0 ;; esac
  if [ "$_raw" -lt 20 ]; then
    _pp_doctor_green "OAR quality" "only ${_raw} labeled rows (need >=20 to evaluate)"
    return 0
  fi

  # jq missing — surface explicitly. Reporting green here would defeat the
  # entire purpose of the check (silent-failure sentinel that itself fails
  # silently).
  if ! command -v jq >/dev/null 2>&1; then
    _pp_doctor_yellow "OAR quality" "jq not installed — cannot evaluate OAR data"
    return 1
  fi

  # Count VALID rows (well-formed objects with .outcome field) and the
  # ignored subset in one pass. Blank/malformed lines are excluded from
  # both numerator and denominator — otherwise an ignored+malformed mix
  # could mask the degenerate pattern PM3 was designed to detect.
  local _counts _jq_rc
  _counts=$(jq -s -r '
      [.[] | select(type=="object" and has("outcome"))] as $v
      | "\($v | length)\t\($v | map(select(.outcome=="ignored")) | length)"
    ' "$_labeled" 2>/dev/null)
  _jq_rc=$?

  # jq error → don't pretend healthy. Fix-the-file rather than silent green.
  if [ "$_jq_rc" -ne 0 ] || [ -z "$_counts" ]; then
    _pp_doctor_yellow "OAR quality" "cannot parse oar-labeled.jsonl (jq error) — check file integrity"
    return 1
  fi

  local _valid _ignored
  _valid=$(printf '%s' "$_counts" | cut -f1)
  _ignored=$(printf '%s' "$_counts" | cut -f2)
  case "$_valid"   in ''|*[!0-9]*) _valid=0   ;; esac
  case "$_ignored" in ''|*[!0-9]*) _ignored=0 ;; esac

  # Raw lines exist but too few parse as valid → file corruption signal.
  if [ "$_valid" -lt 20 ]; then
    _pp_doctor_yellow "OAR quality" "${_raw} raw lines but only ${_valid} parseable — check file integrity"
    return 1
  fi

  # Red-flag condition: >=20 valid rows AND every single one is "ignored."
  # Either (a) the codebase genuinely has zero advisory uptake (improbable;
  # operator should still see this), or (b) pp_oar_referenced is silently
  # broken — the pre-mortem scenario PM3 was authored to detect.
  if [ "$_ignored" -eq "$_valid" ]; then
    _pp_doctor_yellow "OAR quality" "ALL ${_valid} labeled rows are 'ignored' — referenced detection may be broken (see polymath history)"
    return 1
  fi

  local _lineage_counts _v2_rows _missing_lineage
  _lineage_counts=$(jq -s -r '
      [.[] | select(type=="object" and has("outcome") and ((.schema_version // 1) >= 2))] as $v2
      | ($v2 | length) as $total
      | ($v2 | map(select(
          (.prompt_versions // null) as $pv
          | if ($pv | type) != "object" then false
            else (($pv["analyst-primary"] | type == "string") and ($pv["critique"] | type == "string"))
            end
        )) | length) as $complete
      | "\($total)\t\($total - $complete)"
    ' "$_labeled" 2>/dev/null)
  _v2_rows=$(printf '%s' "$_lineage_counts" | cut -f1)
  _missing_lineage=$(printf '%s' "$_lineage_counts" | cut -f2)
  case "$_v2_rows" in ''|*[!0-9]*) _v2_rows=0 ;; esac
  case "$_missing_lineage" in ''|*[!0-9]*) _missing_lineage=0 ;; esac
  if [ "$_v2_rows" -ge 20 ] && [ "$_missing_lineage" -gt 0 ]; then
    _pp_doctor_yellow "OAR quality" "${_missing_lineage}/${_v2_rows} v2 labeled rows missing prompt lineage — prompt improvement loops cannot attribute outcomes"
    return 1
  fi

  if [ -n "${_project_id:-}" ]; then
    _identity_counts=$( { cat "$_labeled" "${_labeled}.1" 2>/dev/null; } \
      | jq -R 'fromjson?' 2>/dev/null \
      | jq -s -r --arg project_id "$_project_id" '
          map(select(type == "object" and ((.schema_version // 1) >= 2))) as $rows
          | ($rows | map(select((.project_id // "") == "")) | length) as $missing
          | ($rows | map(select((.project_id // "") != "" and .project_id != $project_id)) | length) as $foreign
          | "\($missing)\t\($foreign)"
        ' 2>/dev/null)
    _missing_identity=$(printf '%s' "$_identity_counts" | cut -f1)
    _foreign_identity=$(printf '%s' "$_identity_counts" | cut -f2)
    case "$_missing_identity" in ''|*[!0-9]*) _missing_identity=0 ;; esac
    case "$_foreign_identity" in ''|*[!0-9]*) _foreign_identity=0 ;; esac
    if [ "$_missing_identity" -gt 0 ] || [ "$_foreign_identity" -gt 0 ]; then
      _pp_doctor_yellow "OAR quality" "labeled project identity drift: ${_missing_identity} v2 rows missing identity, ${_foreign_identity} rows from another project; history defaults to current project"
      return 1
    fi
  fi

  _pp_doctor_green "OAR quality" "${_valid} rows; ignored=${_ignored} (non-degenerate)"
  return 0
}

doctor_check_statusline_refresh_interval() {
  # v0.5.5 fix — flag missing refreshInterval in settings.json.
  #
  # Symptom this catches: idle Claude Code sessions never re-run the
  # statusline. Per the Claude Code docs, statusline only runs on
  # specific events (new assistant message, /compact, permission mode
  # change, vim mode toggle) unless refreshInterval is set. Without it,
  # `polymath disable` doesn't propagate to idle sessions until the
  # user activates them — confusing pause experience.
  #
  # Fix the user can run: jq '.statusLine.refreshInterval = 1' on their
  # settings.json. Future polymath installs already get refreshInterval=2
  # from the installer (bin/install.sh:794).
  local _settings="${CLAUDE_DIR:-$HOME/.claude}/settings.json"
  if [ ! -f "$_settings" ]; then
    # Other checks already flag missing settings.json; don't double-report.
    _pp_doctor_green "statusline refresh" "skipped (no settings.json)"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _pp_doctor_yellow "statusline refresh" "jq missing — cannot verify refreshInterval"
    return 1
  fi
  local _interval
  _interval=$(jq -r '.statusLine.refreshInterval // empty' "$_settings" 2>/dev/null)
  if [ -z "$_interval" ]; then
    _pp_doctor_yellow "statusline refresh" "refreshInterval missing — idle sessions won't pick up polymath disable/enable. Fix: jq '.statusLine.refreshInterval = 1' $_settings | sponge $_settings  (or use a tmp file + mv)"
    return 1
  fi
  _pp_doctor_green "statusline refresh" "refreshInterval=${_interval}s (idle sessions refresh on a timer)"
  return 0
}

doctor_check_drift_count() {
  # v0.5.1.1 Stage B (Task 13) — drift_count > 0 invariant alarm.
  #
  # Spec AC #3: canonical_allowlist_sha8 (prompt-side) MUST equal
  # canonical_allowlist_sha8 (validator-side) for every cycle. Stage A Task 3
  # stamps both into every verdict file as # v2: comment lines. This check
  # walks the last 24h of verdict files and counts divergences.
  #
  # IMPLEMENTER NOTE (B2): Stage A as currently shipped (bin/statusline.sh:75)
  # stamps a SINGLE `canonical_allowlist_sha8=<8hex>` field rather than the
  # dual `_prompt`/`_validator` pair the plan-task assumes. The divergence
  # only materialises in Stage C, when the rendered prompt block flips to
  # top-N truncation while the validator still consumes the full inventory.
  # Until then, real verdicts don't carry the dual-hash form, so the regex
  # below finds nothing, _total stays 0, and the check is conservatively
  # GREEN ("no verdict data") rather than alarming on absent data. This is
  # the requested cold-start safety: alarm only when we have v2 fields AND
  # they disagree. Stage C will back-patch the verdict writer to emit both
  # hashes (tracked as a plan bug — see plan-task self-review report).
  #
  # Returns:
  #   0 = green (no v2 verdicts in window OR drift_count = 0)
  #   1 = yellow (drift_count > 0; the unified-inventory pipeline has split)
  #
  # Walks ~/.claude/cache/cc-monitor-*-verdict.txt, mtime within 24h.
  # Bash 3.2: no `mapfile`; use a here-doc fed from `find`.
  local _cache_dir="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
  if [ ! -d "$_cache_dir" ]; then
    _pp_doctor_green "drift count" "no verdict data (cache dir absent)"
    return 0
  fi

  # 24h window. find -mtime -1 is "modified in the last 24h" on both
  # GNU and BSD find. Use -name glob (works everywhere).
  local _drift=0 _total=0
  local _f _p_sha _v_sha
  # `2>/dev/null` swallows find's "no such file" on empty dirs.
  while IFS= read -r _f; do
    [ -z "$_f" ] && continue
    _total=$((_total + 1))
    # Both hashes are on lines like "# v2: canonical_allowlist_sha8_prompt=abcd1234"
    _p_sha=$(grep -E '^# v2: canonical_allowlist_sha8_prompt=' "$_f" 2>/dev/null \
             | head -1 | sed 's/.*=//')
    _v_sha=$(grep -E '^# v2: canonical_allowlist_sha8_validator=' "$_f" 2>/dev/null \
             | head -1 | sed 's/.*=//')
    # Missing either hash = pre-Stage-A verdict (v1 row) OR Stage-A
    # single-hash verdict (current shipping format); skip from numerator +
    # denominator. The dual-hash form arrives with Stage C.
    if [ -z "$_p_sha" ] || [ -z "$_v_sha" ]; then
      _total=$((_total - 1))
      continue
    fi
    if [ "$_p_sha" != "$_v_sha" ]; then
      _drift=$((_drift + 1))
    fi
  done <<EOF
$(find "$_cache_dir" -maxdepth 1 -name 'cc-monitor-*-verdict.txt' -type f -mtime -1 2>/dev/null)
EOF

  if [ "$_total" -eq 0 ]; then
    _pp_doctor_green "drift count" "no verdict data with v2 hashes in last 24h"
    return 0
  fi

  if [ "$_drift" -gt 0 ]; then
    _pp_doctor_yellow "drift count" \
      "drift_count=${_drift} of ${_total} verdicts in last 24h — inventory pipeline split (run polymath logs)"
    return 1
  fi
  _pp_doctor_green "drift count" "drift_count=0 across ${_total} verdicts in last 24h"
  return 0
}

doctor_check_statusline_smoke() {
  local fixture="$PP_ROOT/test/fixtures/stdin-sample.json"
  if [ ! -f "$fixture" ]; then
    _pp_doctor_yellow "statusline smoke" "no test fixture"
    return 1
  fi
  if cat "$fixture" | bash "$PP_ROOT/bin/statusline.sh" >/dev/null 2>&1; then
    _pp_doctor_green "statusline smoke" "exit 0 on sample stdin"
    return 0
  fi
  _pp_doctor_red "statusline smoke" "statusline.sh failed on sample stdin"
  return 2
}

doctor_check_network() {
  # Only when --network flag passed. Costs ~$0.0001. Bounded by 15s timeout
  # to prevent DNS/TLS stalls (review fix M3). Match the model's reply exactly,
  # not as a substring, so an error message that happens to contain "ok" can't
  # false-pass (review fix M2).
  if ! command -v llm >/dev/null 2>&1; then
    _pp_doctor_yellow "network probe" "skipped (no llm)"
    return 1
  fi
  local timeout_cmd=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout 15"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout 15"
  fi
  local out trimmed
  out=$($timeout_cmd llm -m gpt-5-mini 'Reply with the single word: ok' 2>&1)
  # Trim whitespace + lowercase + take first line for exact comparison
  trimmed=$(printf '%s' "$out" | head -1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  if [ "$trimmed" = "ok" ]; then
    _pp_doctor_green "network probe" "OpenAI reachable; key works"
    return 0
  fi
  _pp_doctor_red "network probe" "failed: ${out:0:100}"
  return 2
}

# === Driver ===

# pp_doctor_run [--network]
# Runs all checks, prints summary, returns 0 if no red, 1 otherwise.
pp_doctor_run() {
  _pp_doctor_init_colors
  local do_network=0
  case "${1:-}" in
    --network) do_network=1 ;;
  esac

  # v0.5.5 brand: ⚛ sigil header. Lazy-source; plain fallback.
  if [ -z "${_PP_BRAND_SOURCED:-}" ]; then
    # shellcheck disable=SC1091
    . "${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/brand.sh" 2>/dev/null || true
  fi
  if type pp_brand_sigil_cycled >/dev/null 2>&1; then
    printf '\n%s %sPair Polymath doctor%s\n' "$(pp_brand_sigil_cycled)" "${_DC_DIM}" "${_DC_RESET}"
  else
    printf '\n%sPair Polymath doctor%s\n' "${_DC_DIM}" "${_DC_RESET}"
  fi
  printf '%sPlugin root:%s %s\n' "${_DC_DIM}" "${_DC_RESET}" "$PP_ROOT"
  printf '%sClaude dir:%s  %s\n' "${_DC_DIM}" "${_DC_RESET}" "${CLAUDE_DIR:-$HOME/.claude}"
  printf '\n'

  local green=0 yellow=0 red=0
  local checks="doctor_check_bash doctor_check_jq doctor_check_llm doctor_check_openai_key \
                doctor_check_settings_json doctor_check_statusline_wired doctor_check_subagent_statusline_wired doctor_check_dim_gate_progress doctor_check_hooks_wired \
                doctor_check_cache_writable doctor_check_budget_file doctor_check_lenses \
                doctor_check_prompts doctor_check_prompt_contracts doctor_check_transcript_libs doctor_check_router_libs \
                doctor_check_coreutils doctor_check_budget_pressure \
                doctor_check_cache_permissions doctor_check_dismiss_libs \
                doctor_check_retry_router_health doctor_check_install_drift \
                doctor_check_oar_quality doctor_check_drift_count \
                doctor_check_statusline_refresh_interval doctor_check_statusline_smoke"
  [ "$do_network" -eq 1 ] && checks="$checks doctor_check_network"

  local check rc
  for check in $checks; do
    "$check"
    rc=$?
    case "$rc" in
      0) green=$((green + 1)) ;;
      1) yellow=$((yellow + 1)) ;;
      *) red=$((red + 1)) ;;
    esac
  done

  printf '\n%sSummary:%s %s%s green%s, %s%s yellow%s, %s%s red%s\n' \
    "${_DC_DIM}" "${_DC_RESET}" \
    "${_DC_GREEN}" "$green" "${_DC_RESET}" \
    "${_DC_YELLOW}" "$yellow" "${_DC_RESET}" \
    "${_DC_RED}" "$red" "${_DC_RESET}"

  if [ "$red" -gt 0 ]; then
    printf 'Status: %sBROKEN%s — fix red items above.\n\n' "${_DC_RED}" "${_DC_RESET}"
    return 1
  elif [ "$yellow" -gt 0 ]; then
    printf 'Status: %sDEGRADED%s — functional but some checks not green.\n\n' "${_DC_YELLOW}" "${_DC_RESET}"
    return 0
  fi
  printf 'Status: %sHEALTHY%s\n\n' "${_DC_GREEN}" "${_DC_RESET}"
  return 0
}
