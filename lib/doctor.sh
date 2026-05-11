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
  local v="${BASH_VERSION%%.*}"
  if [ "${v:-0}" -ge 3 ]; then
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

doctor_check_statusline_wired() {
  local settings="${CLAUDE_DIR:-$HOME/.claude}/settings.json"
  [ -f "$settings" ] || { _pp_doctor_yellow "statusLine wired" "skipped (no settings.json)"; return 1; }
  local cmd
  cmd=$(jq -r '.statusLine?.command // ""' "$settings" 2>/dev/null)
  if [ -z "$cmd" ]; then
    _pp_doctor_yellow "statusLine wired" "no statusLine in settings.json"
    return 1
  fi
  case "$cmd" in
    *statusline.sh*) _pp_doctor_green "statusLine wired" "→ statusline.sh" ;;
    *) _pp_doctor_yellow "statusLine wired" "points elsewhere: $cmd" ;;
  esac
  return 0
}

doctor_check_hooks_wired() {
  local settings="${CLAUDE_DIR:-$HOME/.claude}/settings.json"
  [ -f "$settings" ] || { _pp_doctor_yellow "hooks wired" "skipped"; return 1; }
  local user_hook post_hook
  user_hook=$(jq -r '[.hooks?.UserPromptSubmit[]?.hooks[]?.command] | map(select(. // "" | test("inject-monitor-insight\\.sh"))) | length' "$settings" 2>/dev/null)
  post_hook=$(jq -r '[.hooks?.PostToolUse[]?.hooks[]?.command]      | map(select(. // "" | test("cache-test-result\\.sh"))) | length' "$settings" 2>/dev/null)
  if [ "${user_hook:-0}" -ge 1 ] && [ "${post_hook:-0}" -ge 1 ]; then
    _pp_doctor_green "hooks wired" "UserPromptSubmit + PostToolUse"
    return 0
  fi
  _pp_doctor_red "hooks wired" "missing (UserPromptSubmit=$user_hook PostToolUse=$post_hook); re-run installer"
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
  # Only when --network flag passed. Costs ~$0.0001.
  if ! command -v llm >/dev/null 2>&1; then
    _pp_doctor_yellow "network probe" "skipped (no llm)"
    return 1
  fi
  local out
  out=$(printf 'ok' | llm -m gpt-5-mini 'reply with the single word: ok' 2>&1)
  case "$out" in
    *ok*) _pp_doctor_green "network probe" "OpenAI reachable; key works" ; return 0 ;;
    *)    _pp_doctor_red   "network probe" "failed: ${out:0:100}" ; return 2 ;;
  esac
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
