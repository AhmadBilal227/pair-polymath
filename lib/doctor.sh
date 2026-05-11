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
                doctor_check_prompts doctor_check_statusline_smoke"
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
