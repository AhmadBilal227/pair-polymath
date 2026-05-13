#!/usr/bin/env bash
# lib/router.sh — LLM-based lens picker + surprise inject.
#
# Owns: the per-cycle decision of WHICH 1..PP_ROUTER_MAX lenses to fire
# this cycle. Reads a signals JSON (from lib/router-signals.sh) plus the
# enabled lens registry, returns NEWLINE-delimited lens IDs.
#
# Public functions:
#   pp_router_pick_lenses <signals_json> <transcript_filtered>
#     → stdout: newline-delimited lens IDs (1..PP_ROUTER_MAX)
#   pp_router_surprise_inject <picked_newline> <not_picked_newline>
#     → stdout: picked set possibly with one off-discipline lens appended
#
# Fail-open contract: ANY failure (router LLM call fails / times out /
# returns garbage / no enabled lenses) returns the full enabled set
# (one per line) so polymath never silently goes dark.
#
# Env vars consumed:
#   PP_ROUTER_ENABLE              1=use router, 0=fan-out-all (rollback)
#   PP_ROUTER_MAX                 max picked per cycle (default 3)
#   PP_ROUTER_MIN                 min picked per cycle (default 1)
#   PP_ROUTER_MODEL               LLM model (default gpt-5-mini)
#   PP_ROUTER_TIMEOUT_S           hard timeout (default 8)
#   PP_ROUTER_SURPRISE_PROB       inject probability (default 0.2)
#   PP_ROUTER_SURPRISE_MAX_TOTAL  cap including surprise (default = MAX)
#   PP_LENS_IDS_AVAILABLE         NEWLINE-delimited enabled lens IDs (C5)
#   PP_RANDOM_SEED                deterministic seed for tests
#   PP_ROUTER_FORCE_OUTPUT        TEST-ONLY: bypass LLM, return this string
#   PP_EVAL_MODE                  1=bypass router (use all enabled)
#
# Bash 3.2-portable. NEWLINE-only API throughout (advisory-compliant).

if [ -n "${_PP_ROUTER_SOURCED:-}" ]; then return 0; fi
_PP_ROUTER_SOURCED=1

# GPT review C1: ensure pp_render_prompt is sourced. Router gets called
# from bin/statusline.sh which already loads prompt-loader, but a future
# caller (doctor check, scripted test) could invoke us in a fresh
# context. Idempotent source-in.
_pp_router_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v pp_render_prompt >/dev/null 2>&1; then
  if [ -r "${_pp_router_self_dir}/prompt-loader.sh" ]; then
    # shellcheck source=prompt-loader.sh
    . "${_pp_router_self_dir}/prompt-loader.sh" 2>/dev/null || true
  fi
fi

: "${PP_ROUTER_ENABLE:=1}"
: "${PP_ROUTER_MAX:=3}"
: "${PP_ROUTER_MIN:=1}"
: "${PP_ROUTER_MODEL:=gpt-5-mini}"
: "${PP_ROUTER_TIMEOUT_S:=8}"
: "${PP_ROUTER_SURPRISE_PROB:=0.2}"
: "${PP_ROUTER_SURPRISE_MAX_TOTAL:=${PP_ROUTER_MAX}}"

# Read newline-delimited PP_LENS_IDS_AVAILABLE into stdout (one per line),
# stripping empty lines. Used everywhere the enabled set is consumed.
_pp_router_emit_enabled() {
  printf '%s\n' "${PP_LENS_IDS_AVAILABLE:-}" | LC_ALL=C grep -v '^$' || true
}

# pp_router_pick_lenses <signals_json> <transcript_filtered>
pp_router_pick_lenses() {
  local _signals="${1:-}"
  local _tx="${2:-}"

  # Hard bypass: ENABLE=0 OR EVAL_MODE=1 → return all enabled.
  if [ "${PP_ROUTER_ENABLE:-1}" != "1" ] || [ "${PP_EVAL_MODE:-0}" = "1" ]; then
    _pp_router_emit_enabled
    return 0
  fi

  # Test-only injection point: skip LLM call.
  local _raw
  if [ -n "${PP_ROUTER_FORCE_OUTPUT+set}" ]; then
    _raw="$PP_ROUTER_FORCE_OUTPUT"
  else
    _raw=$(_pp_router_llm_call "$_signals" "$_tx")
  fi

  # Fail-open EARLY: an empty router result (no LLM, timeout, refused)
  # is the canonical failure mode. Floor-padding to MIN would silently
  # mask this — fan out to ALL enabled instead so polymath never goes
  # dark when the router fails.
  if [ -z "$_raw" ]; then
    _pp_router_emit_enabled
    return 0
  fi

  # Normalize: trim + strict regex post-filter (I1 + I6). Case is
  # PRESERVED — real lens IDs in this repo are UPPERCASE_UNDERSCORE
  # (UX_DESIGN, ENGINEERING, ...). Earlier draft lowercased here, which
  # would have rejected every real ID after the regex pass and silently
  # collapsed to fail-open in production (caught by the 4-way ralph
  # review). Regex now accepts both cases plus underscores and slashes
  # so v0.4 Phase 4 category-prefixed IDs (executive/cfo) also pass.
  local _validated="" _seen="" _line _norm
  while IFS= read -r _line; do
    # Trim leading/trailing whitespace.
    _norm=$(printf '%s' "$_line" | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$_norm" ] && continue
    # Strict regex: must match ^[A-Za-z][A-Za-z0-9_/-]*$. Rejects
    # bullets, numbered lists, anything with leading punctuation/quotes.
    if ! printf '%s' "$_norm" | LC_ALL=C grep -qE '^[A-Za-z][A-Za-z0-9_/-]*$'; then
      continue
    fi
    # Must be in enabled set + not yet picked. Case-sensitive: registry
    # owns the canonical casing.
    if _pp_router_emit_enabled | LC_ALL=C grep -qxF "$_norm"; then
      case " $_seen " in
        *" $_norm "*) ;;
        *)
          _validated="${_validated}${_norm}"$'\n'
          _seen="$_seen $_norm"
        ;;
      esac
    fi
  done <<EOF
$_raw
EOF

  # Floor: pad from enabled set until we hit PP_ROUTER_MIN.
  local _count
  _count=$(printf '%s' "$_validated" | LC_ALL=C grep -c '^.' 2>/dev/null)
  _count="${_count:-0}"
  if [ "$_count" -lt "${PP_ROUTER_MIN:-1}" ]; then
    local _pad
    while IFS= read -r _pad; do
      [ -z "$_pad" ] && continue
      case " $_seen " in
        *" $_pad "*) ;;
        *)
          _validated="${_validated}${_pad}"$'\n'
          _seen="$_seen $_pad"
          _count=$((_count + 1))
        ;;
      esac
      [ "$_count" -ge "${PP_ROUTER_MIN:-1}" ] && break
    done <<EOF
$(_pp_router_emit_enabled)
EOF
  fi

  # Fail-open: if STILL nothing validated (e.g., empty enabled set or
  # router returned only invalid IDs), return everything enabled.
  if [ -z "$_validated" ]; then
    _pp_router_emit_enabled
    return 0
  fi

  # Cap at MAX: tail-clip extras.
  printf '%s' "$_validated" | LC_ALL=C grep -v '^$' | head -n "${PP_ROUTER_MAX:-3}"
}

# Internal: invoke the LLM with timeout. Returns raw model output on
# stdout. On timeout / no llm binary / no timeout binary fallback path,
# emits empty (caller falls open). Per C2: works without coreutils.
_pp_router_llm_call() {
  local _signals="$1" _tx="$2"
  command -v llm >/dev/null 2>&1 || { printf ''; return 0; }

  # Build the lens registry block (one id per line).
  local _registry
  _registry=$(_pp_router_emit_enabled)

  # 5-line tail of the transcript for tie-breaking (I5).
  local _tx_5
  _tx_5=$(printf '%s' "$_tx" | LC_ALL=C tail -n 5)

  # Render prompt via the project's allowlist-gated loader.
  local _prompt
  _prompt=$(
    signals_json="$_signals" \
    transcript_tail_5="$_tx_5" \
    lens_registry="$_registry" \
    PP_ROUTER_MIN="${PP_ROUTER_MIN:-1}" \
    PP_ROUTER_MAX="${PP_ROUTER_MAX:-3}" \
    pp_render_prompt router 2>/dev/null
  )

  # C2: timeout portability. Prefer timeout > gtimeout > bash background-
  # spawn fallback for macOS-without-coreutils. The fallback kills the
  # child after PP_ROUTER_TIMEOUT_S seconds via a watchdog subshell.
  if command -v timeout >/dev/null 2>&1; then
    timeout "${PP_ROUTER_TIMEOUT_S:-8}" llm -m "${PP_ROUTER_MODEL:-gpt-5-mini}" -s "$_prompt" "Pick lenses." 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${PP_ROUTER_TIMEOUT_S:-8}" llm -m "${PP_ROUTER_MODEL:-gpt-5-mini}" -s "$_prompt" "Pick lenses." 2>/dev/null
  else
    # P2.5 Track 1.1: portable bounded-wait. Use `exec` inside the bg
    # subshell so the subshell BECOMES the llm process — killing $_pid
    # then kills llm directly (no grandchild orphan). Belt-and-suspenders:
    # also attempt process-group kill (kill -- -$_pid) for systems where
    # llm forks children of its own (e.g., python wrapper spawning curl).
    # GPT plan-review C1: was reintroducing bg-spawn + plain kill; now
    # exec'd subshell + dual kill path eliminates the orphan-curl risk.
    local _outfile
    _outfile=$(mktemp)
    (
      exec llm -m "${PP_ROUTER_MODEL:-gpt-5-mini}" -s "$_prompt" "Pick lenses." 2>/dev/null > "$_outfile"
    ) &
    local _pid=$!
    local _waited=0
    while [ "$_waited" -lt "${PP_ROUTER_TIMEOUT_S:-8}" ] && kill -0 "$_pid" 2>/dev/null; do
      sleep 1
      _waited=$((_waited + 1))
    done
    if kill -0 "$_pid" 2>/dev/null; then
      kill -KILL -- "-$_pid" 2>/dev/null || true
      kill -KILL "$_pid" 2>/dev/null || true
    fi
    wait "$_pid" 2>/dev/null || true
    cat "$_outfile" 2>/dev/null
    rm -f "$_outfile" 2>/dev/null
  fi
}

# pp_router_surprise_inject <picked_newline> <not_picked_newline>
# Both args are NEWLINE-delimited (I4). Output is also newline-delimited.
# With PP_ROUTER_SURPRISE_PROB probability, append one random off-
# discipline lens. Deterministic when PP_RANDOM_SEED is set.
pp_router_surprise_inject() {
  local _picked="$1"
  local _candidates="$2"
  local _prob="${PP_ROUTER_SURPRISE_PROB:-0.2}"

  # Roll the dice (deterministic if PP_RANDOM_SEED set).
  local _roll
  if [ -n "${PP_RANDOM_SEED:-}" ]; then
    _roll=$(LC_ALL=C awk -v seed="$PP_RANDOM_SEED" 'BEGIN{srand(seed); printf "%.4f", rand()}')
  else
    _roll=$(LC_ALL=C awk 'BEGIN{srand(); printf "%.4f", rand()}')
  fi

  # Count current picked set.
  local _total
  _total=$(printf '%s\n' "$_picked" | LC_ALL=C grep -c '^.')
  _total="${_total:-0}"

  # Dedupe candidates against picked set.
  local _clean_candidates="" _c
  while IFS= read -r _c; do
    [ -z "$_c" ] && continue
    case $'\n'"$_picked"$'\n' in
      *$'\n'"$_c"$'\n'*) ;;
      *) _clean_candidates="${_clean_candidates}${_c}"$'\n' ;;
    esac
  done <<EOF
$_candidates
EOF

  # Decide whether to inject + we have a candidate + total < cap.
  if [ -n "$_clean_candidates" ] && \
     LC_ALL=C awk -v r="$_roll" -v p="$_prob" 'BEGIN{exit !(r<p)}' && \
     [ "$_total" -lt "${PP_ROUTER_SURPRISE_MAX_TOTAL:-${PP_ROUTER_MAX:-3}}" ]; then
    # Pick deterministically from cleaned candidates.
    local _cand_count _idx _surprise
    _cand_count=$(printf '%s' "$_clean_candidates" | LC_ALL=C grep -c '^.')
    _cand_count="${_cand_count:-1}"
    [ "$_cand_count" -lt 1 ] && _cand_count=1
    _idx=$(LC_ALL=C awk -v seed="${PP_RANDOM_SEED:-$$}" -v n="$_cand_count" 'BEGIN{srand(seed); printf "%d", int(rand()*n)+1}')
    _surprise=$(printf '%s' "$_clean_candidates" | LC_ALL=C grep -v '^$' | sed -n "${_idx}p")
    if [ -n "$_surprise" ]; then
      printf '%s\n%s\n' "$_picked" "$_surprise" | LC_ALL=C grep -v '^$'
      return 0
    fi
  fi
  # No injection: emit picked as-is, strip blank lines.
  printf '%s\n' "$_picked" | LC_ALL=C grep -v '^$'
}
