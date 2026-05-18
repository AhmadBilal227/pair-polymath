#!/usr/bin/env bash
# Pair Polymath — display-only fun mode helpers.
# Function-only library. It must never inject into Claude context or alter
# advisor/runtime decisions.

if [ -n "${_PP_FUN_MODE_SOURCED:-}" ]; then return 0; fi
_PP_FUN_MODE_SOURCED=1

pp_fun_style_normalize() {
  case "${1:-mentor}" in
    gentle|hype|dry|mentor|founder|roast) printf '%s' "$1" ;;
    *) printf 'mentor' ;;
  esac
}

pp_fun_intensity_normalize() {
  case "${1:-1}" in
    1|2|3) printf '%s' "$1" ;;
    *) printf '1' ;;
  esac
}

pp_fun_max_chars_normalize() {
  local _max="${1:-120}"
  case "$_max" in ''|*[!0-9]*) _max=120 ;; esac
  [ "$_max" -lt 40 ] && _max=40
  [ "$_max" -gt 240 ] && _max=240
  printf '%s' "$_max"
}

pp_fun_cooldown_s_normalize() {
  local _cooldown="${1:-300}"
  case "$_cooldown" in ''|*[!0-9]*) _cooldown=300 ;; esac
  [ "$_cooldown" -lt 0 ] && _cooldown=300
  [ "$_cooldown" -gt 86400 ] && _cooldown=86400
  printf '%s' "$_cooldown"
}

pp_fun_trim() {
  local _s="$1" _max="$2"
  if [ "${#_s}" -gt "$_max" ]; then
    printf '%s...' "$(printf '%s' "$_s" | cut -c1-$((_max - 3)))"
  else
    printf '%s' "$_s"
  fi
}

pp_fun_message_for_signal() {
  local _style="$1" _signal="$2"
  case "$_style:$_signal" in
    gentle:test_fail) printf 'Tests are talking. Shrink the repro before changing more files.' ;;
    gentle:budget_low) printf 'Budget is tight. Let the best lens speak and skip the chorus.' ;;
    gentle:context_high) printf 'Context is getting heavy. A short checkpoint will pay for itself.' ;;
    gentle:dirty) printf 'Good moment for a small verification pass before the diff grows.' ;;
    gentle:idle) printf 'Quiet stretch. Capture the next tiny step before context cools.' ;;
    hype:test_fail) printf 'Red test, clean target. One assertion, one fix, then move.' ;;
    hype:budget_low) printf 'Spend pressure is real. Make the next call count.' ;;
    hype:context_high) printf 'High-context zone. Summarize, checkpoint, keep shipping.' ;;
    hype:dirty) printf 'Diff has momentum. Lock it with tests.' ;;
    hype:idle) printf 'Warm start: pick the sharpest next step.' ;;
    dry:test_fail) printf 'The test suite has filed a complaint. Read the first failing line.' ;;
    dry:budget_low) printf 'The meter is blinking. Maybe do not invite every advisor to the meeting.' ;;
    dry:context_high) printf 'The context window is carrying luggage. Pack lighter.' ;;
    dry:dirty) printf 'The worktree is seasoned. Verification would not hurt.' ;;
    dry:idle) printf 'No fresh signal. Even the statusline is being polite.' ;;
    founder:test_fail) printf 'A failing test is a revenue leak in disguise. Isolate it now.' ;;
    founder:budget_low) printf 'Budget pressure: spend premium calls only where they change the decision.' ;;
    founder:context_high) printf 'Context is expensive. Convert it into a decision before it decays.' ;;
    founder:dirty) printf 'Unverified diff equals unfinished inventory. Close the loop.' ;;
    founder:idle) printf 'Idle time is fine. Unnamed next steps are not.' ;;
    roast:test_fail) printf 'The process is trying the same door twice. Smaller repro, fewer bruises.' ;;
    roast:budget_low) printf 'The budget meter saw that extra fan-out and raised an eyebrow.' ;;
    roast:context_high) printf 'This context window is now a storage unit. Summarize before adding boxes.' ;;
    roast:dirty) printf 'That diff is developing plot. Give it tests before it gets a sequel.' ;;
    roast:idle) printf 'The session is parked. Put one next action on the windshield.' ;;
    mentor:test_fail|*:test_fail) printf 'Loop risk: keep the failing output fixed, change one thing, rerun.' ;;
    mentor:budget_low|*:budget_low) printf 'Budget is near cap. Prefer deterministic checks before another LLM cycle.' ;;
    mentor:context_high|*:context_high) printf 'Context pressure is high. Ask for a compact state summary soon.' ;;
    mentor:dirty|*:dirty) printf 'Worktree has changes. Verify the smallest useful slice before expanding.' ;;
    mentor:idle|*:idle) printf 'No fresh insight yet. Restart with one concrete next check.' ;;
    *) printf 'Keep the next move small, evidenced, and easy to verify.' ;;
  esac
}

pp_fun_pick_signal() {
  local _test_error="${PP_FUN_TEST_ERROR:-unknown}"
  local _dirty="${PP_FUN_GIT_DIRTY:-0}"
  local _budget="${PP_FUN_BUDGET_PCT:-100}"
  local _context="${PP_FUN_CONTEXT_PCT:-0}"
  local _idle="${PP_FUN_IDLE_S:-0}"

  case "$_budget" in ''|*[!0-9]*) _budget=100 ;; esac
  case "$_context" in ''|*[!0-9]*) _context=0 ;; esac
  case "$_idle" in ''|*[!0-9]*) _idle=0 ;; esac

  if [ "$_test_error" = "true" ]; then
    printf 'test_fail'
  elif [ "$_budget" -le 10 ]; then
    printf 'budget_low'
  elif [ "$_context" -ge 80 ]; then
    printf 'context_high'
  elif [ "$_dirty" = "1" ]; then
    printf 'dirty'
  elif [ "$_idle" -ge 900 ]; then
    printf 'idle'
  else
    printf 'default'
  fi
}

pp_fun_cooldown_allows() {
  local _file="${PP_FUN_COOLDOWN_FILE:-}"
  local _cooldown _now _last="" _dir _tmp
  _cooldown=$(pp_fun_cooldown_s_normalize "${PP_FUN_COOLDOWN_S:-300}")
  [ "$_cooldown" -eq 0 ] && return 0
  [ -n "$_file" ] || return 0

  _now="${PP_FUN_NOW:-$(date +%s 2>/dev/null || printf '0')}"
  case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
  if [ -f "$_file" ]; then
    _last=$(head -n 1 "$_file" 2>/dev/null || true)
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    if [ $((_now - _last)) -lt "$_cooldown" ] 2>/dev/null; then
      return 1
    fi
  fi

  _dir=$(dirname "$_file")
  mkdir -p "$_dir" 2>/dev/null || return 0
  _tmp=$(mktemp "${_file}.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$_now" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 0; }
  mv "$_tmp" "$_file" 2>/dev/null || { rm -f "$_tmp"; return 0; }
  return 0
}

pp_fun_render() {
  [ "${PP_FUN_MODE:-0}" = "1" ] || return 1
  pp_fun_cooldown_allows || return 1

  local _style _signal _max _msg
  _style=$(pp_fun_style_normalize "${PP_FUN_STYLE:-mentor}")
  if [ "$_style" = "roast" ] && [ "${PP_FUN_ALLOW_ROAST:-0}" != "1" ]; then
    _style="dry"
  fi
  pp_fun_intensity_normalize "${PP_FUN_INTENSITY:-1}" >/dev/null
  _max=$(pp_fun_max_chars_normalize "${PP_FUN_MAX_CHARS:-120}")
  _signal=$(pp_fun_pick_signal)
  _msg=$(pp_fun_message_for_signal "$_style" "$_signal")
  pp_fun_trim "$_msg" "$_max"
  return 0
}
