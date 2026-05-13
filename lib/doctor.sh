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

doctor_check_hooks_wired() {
  local settings="${CLAUDE_DIR:-$HOME/.claude}/settings.json"
  [ -f "$settings" ] || { _pp_doctor_yellow "hooks wired" "skipped"; return 1; }

  # Strict-match: hook command must resolve to OUR script under $PP_ROOT/hooks/,
  # not just any file with that basename (review fix H2).
  local want_user want_post
  want_user=$(cd "$PP_ROOT" 2>/dev/null && realpath "hooks/inject-monitor-insight.sh" 2>/dev/null)
  want_post=$(cd "$PP_ROOT" 2>/dev/null && realpath "hooks/cache-test-result.sh" 2>/dev/null)

  local user_match=0 post_match=0
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

  if [ "$user_match" -eq 1 ] && [ "$post_match" -eq 1 ]; then
    _pp_doctor_green "hooks wired" "UserPromptSubmit + PostToolUse → \$PP_ROOT/hooks"
    return 0
  fi
  _pp_doctor_red "hooks wired" "missing or pointing elsewhere (UserPromptSubmit=$user_match PostToolUse=$post_match); re-run installer"
  return 2
}

doctor_check_cache_writable() {
  local d="${PP_CACHE_DIR:-$HOME/.claude/cache}"
  mkdir -p "$d" 2>/dev/null
  if [ -w "$d" ]; then
    _pp_doctor_green "cache dir writable" "$d"
    return 0
  fi
  _pp_doctor_red "cache dir writable" "$d is not writable"
  return 2
}

doctor_check_budget_file() {
  local f="${PP_CACHE_DIR:-$HOME/.claude/cache}/pp-budget-$(date +%Y%m%d).txt"
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
  local expected="planner analyst-primary analyst-retry critique escalation-investigation tip-digest"
  local missing=""
  local p
  for p in $expected; do
    [ -f "$PP_ROOT/prompts/$p.md" ] || missing="$missing $p"
  done
  if [ -z "$missing" ]; then
    _pp_doctor_green "prompts" "6/6 built-in present"
    return 0
  fi
  _pp_doctor_red "prompts" "missing:$missing"
  return 2
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
      PP_LENS_IDS_AVAILABLE="ENGINEERING"$'\n'"SECURITY" \
        PP_ROUTER_FORCE_OUTPUT="ENGINEERING" \
        _picked=$(pp_router_pick_lenses "$_signals" "probe")
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

  printf '\n%sPair Polymath doctor%s\n' "${_DC_DIM}" "${_DC_RESET}"
  printf '%sPlugin root:%s %s\n' "${_DC_DIM}" "${_DC_RESET}" "$PP_ROOT"
  printf '%sClaude dir:%s  %s\n' "${_DC_DIM}" "${_DC_RESET}" "${CLAUDE_DIR:-$HOME/.claude}"
  printf '\n'

  local green=0 yellow=0 red=0
  local checks="doctor_check_bash doctor_check_jq doctor_check_llm doctor_check_openai_key \
                doctor_check_settings_json doctor_check_statusline_wired doctor_check_hooks_wired \
                doctor_check_cache_writable doctor_check_budget_file doctor_check_lenses \
                doctor_check_prompts doctor_check_transcript_libs doctor_check_router_libs \
                doctor_check_coreutils doctor_check_budget_pressure \
                doctor_check_cache_permissions doctor_check_statusline_smoke"
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
