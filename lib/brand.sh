#!/usr/bin/env bash
# Pair Polymath — brand identity (v0.5.5).
# Spec: docs/v0.5.5-brand-spec.md
# Brand book: docs/brand.md
#
# Owns: two marks.
#   1. `⚛` (U+269B) — the polymath sigil. Many specialists orbiting work.
#      Color-cycles through the lens palette to signal which lens "spoke."
#   2. Constellation `⠁ ⠂ ⠄ ⡀` — 4-frame braille loading mark. Time-cycled
#      at 1s per frame. Says "many minds quietly attending."
#
# Voice: respectful pair-programmer, not notification system. Quiet
# presence over loud signals. Never adds animation that doesn't already
# move (the dot stays still; color or position cycles).

# Idempotent source guard (same pattern as lib/oar.sh, lib/hallucination.sh).
if [ -n "${_PP_BRAND_SOURCED:-}" ]; then
  if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    return 0
  else
    exit 0
  fi
fi
_PP_BRAND_SOURCED=1

# === The polymath sigil ====================================================
# U+269B ATOM SYMBOL. Broad font support across modern terminals. Falls
# back to '*' if the terminal is ASCII-only (rare; detected by env LANG).
_pp_brand_sigil() {
  # ASCII-fallback detection: when LANG ends in 'POSIX' or '@C', the
  # terminal may not render U+269B reliably. Cheap heuristic; users can
  # override with PP_BRAND_SIGIL_ASCII=1.
  if [ "${PP_BRAND_SIGIL_ASCII:-0}" = "1" ]; then
    printf '%s' '*'
    return 0
  fi
  case "${LANG:-}" in
    *.UTF-8|*.utf8|*.UTF8|*UTF-8*|*utf-8*) printf '%s' '⚛' ;;
    *)                                     printf '%s' '*' ;;
  esac
}

# === The constellation (loading mark) ======================================
# 4 frames per ui-designer review ("presence not buzzing"). Time-cycled by
# wall-clock — no inter-process state to coordinate, no flicker risk.
_PP_BRAND_FRAMES='⠁ ⠂ ⠄ ⡀'

_pp_brand_loading_frame() {
  # Pick the frame index from wall-clock seconds (1s per frame).
  local _now _idx
  _now=$(date +%s 2>/dev/null) || _now=0
  _idx=$(( _now % 4 ))
  case "$_idx" in
    0) printf '%s' '⠁' ;;
    1) printf '%s' '⠂' ;;
    2) printf '%s' '⠄' ;;
    3) printf '%s' '⡀' ;;
  esac
}

# === The lens palette (locked in v0.5.5) ====================================
# Six distinct hues across 7 lenses. STRATEGIC_FOUNDER moved from
# SOFT_PURPLE → SOFT_BLUE per ui-designer accessibility review (shared-hue
# collision with UX_DESIGN under deuteranopia).
_pp_brand_lens_hue() {
  local _lens="${1:-}"
  case "$_lens" in
    UX_DESIGN)         printf '\033[38;5;139m' ;;  # SOFT_PURPLE
    ENGINEERING)       printf '\033[38;5;179m' ;;  # SOFT_AMBER
    SECURITY)          printf '\033[38;5;167m' ;;  # SOFT_CRIMSON
    PERF_FINOPS)       printf '\033[38;5;108m' ;;  # SOFT_GREEN
    PRODUCT_BIZ)       printf '\033[38;5;117m' ;;  # CYAN_SOFT
    STRATEGIC_FOUNDER) printf '\033[38;5;110m' ;;  # SOFT_BLUE (a11y fix)
    COGNITIVE_FLOW)    printf '\033[38;5;243m' ;;  # DIM_GRAY
    *)                 printf '\033[38;5;139m' ;;  # default: SOFT_PURPLE
  esac
}

# Cycle hue by wall-clock — for `⚛` in idle/info contexts (e.g., polymath
# status header). 30s per hue = ~3.5 minute full cycle. Slow enough to
# feel quiet, fast enough to notice over a working session.
_pp_brand_cycle_hue() {
  local _now _idx _lenses
  _now=$(date +%s 2>/dev/null) || _now=0
  _idx=$(( (_now / 30) % 7 ))
  _lenses=(UX_DESIGN ENGINEERING SECURITY PERF_FINOPS PRODUCT_BIZ STRATEGIC_FOUNDER COGNITIVE_FLOW)
  _pp_brand_lens_hue "${_lenses[$_idx]}"
}

# === Composite helpers (for use sites) =====================================
# pp_brand_sigil_for_lens <LENS_ID> — sigil rendered in that lens's hue.
pp_brand_sigil_for_lens() {
  local _lens="${1:-}"
  printf '%s%s\033[0m' "$(_pp_brand_lens_hue "$_lens")" "$(_pp_brand_sigil)"
}

# pp_brand_sigil_cycled — sigil in the wall-clock-rotating hue (idle voice).
pp_brand_sigil_cycled() {
  printf '%s%s\033[0m' "$(_pp_brand_cycle_hue)" "$(_pp_brand_sigil)"
}

# pp_brand_sigil_plain — uncolored sigil (for plain contexts like the
# subagent statusline where 7 simultaneous colored sigils would strobe).
pp_brand_sigil_plain() {
  _pp_brand_sigil
}

# pp_brand_loading — current constellation frame, no color.
pp_brand_loading() {
  _pp_brand_loading_frame
}

# === ASCII banner (first-touch surface only) ===============================
# Inspired by oh-my-logo (Claude Code / Gemini CLI splash style). Used in
# bin/install.sh + polymath onboard intro — NEVER in statusline. Keep it
# 7 lines tall (one per lens) so it fits any terminal with room.
pp_brand_banner() {
  local _hue
  _hue=$(_pp_brand_lens_hue UX_DESIGN)
  printf '%s' "$_hue"
  cat <<'EOF'
  ██████   █████  ██ ██████      ██████   ██████  ██   ██   ██ ███    ███  █████  ████████ ██   ██
  ██   ██ ██   ██ ██ ██   ██     ██   ██ ██    ██ ██    ██ ██  ████  ████ ██   ██    ██    ██   ██
  ██████  ███████ ██ ██████      ██████  ██    ██ ██     ███   ██ ████ ██ ███████    ██    ███████
  ██      ██   ██ ██ ██   ██     ██      ██    ██ ██      ██   ██  ██  ██ ██   ██    ██    ██   ██
  ██      ██   ██ ██ ██   ██     ██       ██████  ███████ ██   ██      ██ ██   ██    ██    ██   ██
EOF
  printf '\033[0m'
}
