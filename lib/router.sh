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

# v0.5.1.1 Stage D — lazy-source the eligibility evaluator. Same
# rationale as prompt-loader above: lib/eligibility.sh is normally
# sourced by bin/statusline.sh before the router fires, but doctor
# checks / scripted tests / standalone callers may not have it.
# Idempotent source-in. Mirrors the lib/oar.sh → lib/grounding.sh
# lazy-source pattern.
if ! command -v pp_lens_is_eligible >/dev/null 2>&1; then
  if [ -r "${_pp_router_self_dir}/eligibility.sh" ]; then
    # shellcheck source=eligibility.sh
    . "${_pp_router_self_dir}/eligibility.sh" 2>/dev/null || true
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

# pp_router_pick_lenses <signals_json> <transcript_filtered> [facts_file]
#
# v0.5.1.1 Stage D: optional third arg is the facts-snapshot path. When
# supplied AND PP_LENS_GATES_ACTIVE=1, the validated pick set is filtered
# through pp_lens_is_eligible (one drop per ineligible pick, replacement
# drawn from the next-ranked eligible lens in PP_LENS_IDS_AVAILABLE
# order). When supplied AND PP_LENS_GATES_TELEMETRY=1, every picked
# lens's would-be-ineligible verdict is appended to
# PP_LENS_GATES_SHADOW_FILE (default ~/.claude/cache/lens-gates-shadow.jsonl).
# Both gates default off — with the default config the function is
# byte-identical to v0.5.1.0.
pp_router_pick_lenses() {
  local _signals="${1:-}"
  local _tx="${2:-}"
  local _facts_file="${3:-}"

  # P2.5 Track 3: cache the enabled-set once per call. Previously
  # invoked _pp_router_emit_enabled 4+ times per call (printf | grep
  # subshell each time). Net saving: ~50-100ms per cycle on cold macOS
  # where fork-exec is expensive. (Code-reviewer M2, AI-engineer I7.)
  local _enabled_cached
  _enabled_cached=$(_pp_router_emit_enabled)

  # Hard bypass: ENABLE=0 OR EVAL_MODE=1 → return all enabled.
  if [ "${PP_ROUTER_ENABLE:-1}" != "1" ] || [ "${PP_EVAL_MODE:-0}" = "1" ]; then
    printf '%s\n' "$_enabled_cached" | LC_ALL=C grep -v '^$' || true
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
    printf '%s\n' "$_enabled_cached" | LC_ALL=C grep -v '^$' || true
    return 0
  fi

  # Normalize: trim + strict regex post-filter (I1 + I6). Case is
  # PRESERVED — real lens IDs in this repo are UPPERCASE_UNDERSCORE
  # (UX_DESIGN, ENGINEERING, ...). Earlier draft lowercased here, which
  # would have rejected every real ID after the regex pass and silently
  # collapsed to fail-open in production (caught by the 4-way ralph
  # review). Regex now accepts both cases plus underscores and slashes
  # so v0.4 Phase 4 category-prefixed IDs (executive/cfo) also pass.
  local _validated="" _seen="" _line _norm _valid_from_raw=0
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
    if printf '%s\n' "$_enabled_cached" | LC_ALL=C grep -qxF "$_norm"; then
      case " $_seen " in
        *" $_norm "*) ;;
        *)
          _validated="${_validated}${_norm}"$'\n'
          _seen="$_seen $_norm"
          _valid_from_raw=1
        ;;
      esac
    fi
  done <<EOF
$_raw
EOF

  # Fail-open: non-empty router output that validates to zero enabled IDs
  # is malformed (markdown bullets, comma text, unknown IDs). Do not floor-
  # pad it into a single arbitrary lens; fan out to all enabled as the
  # router prompt and fail-open contract promise.
  if [ "$_valid_from_raw" != "1" ]; then
    printf '%s\n' "$_enabled_cached" | LC_ALL=C grep -v '^$' || true
    return 0
  fi

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
$_enabled_cached
EOF
  fi

  # Fail-open: if STILL nothing validated (e.g., empty enabled set or
  # router returned only invalid IDs), return everything enabled.
  if [ -z "$_validated" ]; then
    printf '%s\n' "$_enabled_cached" | LC_ALL=C grep -v '^$' || true
    return 0
  fi

  # ============================================================================
  # v0.5.1.1 Stage D — eligibility filter + replacement draw.
  # ============================================================================
  #
  # When PP_LENS_GATES_ACTIVE=1 AND a facts file is supplied, filter the
  # validated pick set through pp_lens_is_eligible. Drop the ineligible
  # picks; for each dropped pick, draw the next-ranked eligible lens from
  # the enabled set (PP_LENS_IDS_AVAILABLE order). Cap at PP_ROUTER_MAX.
  #
  # When PP_LENS_GATES_TELEMETRY=1, stamp every PICKED lens's would-be-
  # ineligible flag into PP_LENS_GATES_SHADOW_FILE (one JSONL row per pick).
  # Runs INDEPENDENTLY of PP_LENS_GATES_ACTIVE — operator can compare what
  # the gate would have done vs what actually happened in shadow mode.
  #
  # Fail-open semantics: if eligibility evaluator is missing (lib not
  # sourced) OR facts file is absent / unreadable, the filter pass is
  # SKIPPED — same as PP_LENS_GATES_ACTIVE=0. No silent dark-mode.
  local _vl _ts _shadow
  if [ "${PP_LENS_GATES_TELEMETRY:-0}" = "1" ] && [ -n "$_facts_file" ] && [ -f "$_facts_file" ] \
     && command -v pp_lens_is_eligible >/dev/null 2>&1; then
    _shadow="${PP_LENS_GATES_SHADOW_FILE:-$HOME/.claude/cache/lens-gates-shadow.jsonl}"
    mkdir -p "$(dirname "$_shadow")" 2>/dev/null || true
    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || _ts="1970-01-01T00:00:00Z"
    while IFS= read -r _vl; do
      [ -z "$_vl" ] && continue
      if pp_lens_is_eligible "$_vl" "$_facts_file"; then
        printf '{"ts":"%s","lens_id":"%s","would_be_ineligible":0}\n' \
          "$_ts" "$_vl" >> "$_shadow" 2>/dev/null
      else
        printf '{"ts":"%s","lens_id":"%s","would_be_ineligible":1}\n' \
          "$_ts" "$_vl" >> "$_shadow" 2>/dev/null
      fi
    done <<EOF
$_validated
EOF
  fi

  if [ "${PP_LENS_GATES_ACTIVE:-0}" = "1" ] && [ -n "$_facts_file" ] && [ -f "$_facts_file" ] \
     && command -v pp_lens_is_eligible >/dev/null 2>&1; then
    # Pass 1: split _validated into eligible vs dropped.
    local _eligible="" _dropped="" _vline _cand _seen_e=""
    while IFS= read -r _vline; do
      [ -z "$_vline" ] && continue
      if pp_lens_is_eligible "$_vline" "$_facts_file"; then
        _eligible="${_eligible}${_vline}"$'\n'
      else
        _dropped="${_dropped}${_vline}"$'\n'
      fi
    done <<EOF
$_validated
EOF

    # Pass 2: for each dropped pick, draw ONE replacement from the
    # enabled set in order, skipping already-picked and ineligible. Stop
    # when we've replaced all drops OR enabled-set is exhausted.
    local _drop_count
    _drop_count=$(printf '%s' "$_dropped" | LC_ALL=C grep -c '^.' 2>/dev/null)
    _drop_count="${_drop_count:-0}"
    if [ "$_drop_count" -gt 0 ]; then
      local _need="$_drop_count"
      # Build _seen_e from current _eligible list (case-sensitive).
      while IFS= read -r _vline; do
        [ -z "$_vline" ] && continue
        _seen_e="${_seen_e} ${_vline}"
      done <<EOF
$_eligible
EOF
      # Also block already-considered (dropped) picks from being re-drawn.
      while IFS= read -r _vline; do
        [ -z "$_vline" ] && continue
        _seen_e="${_seen_e} ${_vline}"
      done <<EOF
$_dropped
EOF
      while IFS= read -r _cand; do
        [ -z "$_cand" ] && continue
        [ "$_need" -le 0 ] && break
        case " $_seen_e " in
          *" $_cand "*) continue ;;
        esac
        if pp_lens_is_eligible "$_cand" "$_facts_file"; then
          _eligible="${_eligible}${_cand}"$'\n'
          _seen_e="$_seen_e $_cand"
          _need=$((_need - 1))
        fi
      done <<EOF
$_enabled_cached
EOF
    fi

    _validated="$_eligible"
  fi
  # ============================================================================
  # END v0.5.1.1 Stage D
  # ============================================================================

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
    # then kills llm directly (no grandchild orphan from the SUBSHELL).
    #
    # Known limitation (AI-eng round-2 I1 / GPT round-2 C3): if `llm`
    # itself forks a child (e.g., python -> curl), SIGKILL'ing the llm
    # PID immediately makes curl an orphan that gets reparented to init
    # and continues until the HTTP response. Worst case: ~$0.001 leaked
    # per timeout (one outbound API call). Previous draft tried
    # `kill -- -$_pid` for process-group cleanup, but without `set -m`
    # the bg subshell inherits the parent's pgroup — that kill would
    # either silently fail (best case) or signal the statusline parent
    # itself (worst case). Removed; documented in docs/cost-model.md.
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
  # P2.5 Track 5 portability note (Debugger I3): awk's srand()
  # implementation differs across gawk / mawk / BusyBox awk. The same
  # integer seed produces DIFFERENT float sequences across
  # implementations. Within a single process (same awk binary, same
  # session) PP_RANDOM_SEED is reliably idempotent for tests. For
  # cross-machine reproducibility (CI matrix asserting exact lens
  # choice on macOS+Linux+Alpine), use PP_RANDOM_SEED_MODULO instead:
  # it bypasses awk via integer modulo (deterministic everywhere bash
  # 3.2 runs). Documented; not a hot-path optimization.
  local _roll
  if [ -n "${PP_RANDOM_SEED_MODULO:-}" ]; then
    # Cross-machine deterministic path. Integer modulo, no awk.
    _roll=$(LC_ALL=C awk -v n="$PP_RANDOM_SEED_MODULO" 'BEGIN{printf "%.4f", (n%100)/100.0}')
  elif [ -n "${PP_RANDOM_SEED:-}" ]; then
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

# ============================================================================
# v0.4 Phase 2.5 Track 2 — Router telemetry
# ============================================================================
#
# pp_router_metrics_emit <signals_json> <picked_newline_or_space>
#                        <surprise_fired_bool> <failopen_bool> <llm_call_ms>
#
# Appends one JSONL line to PP_ROUTER_METRICS_FILE for the cycle.
# Schema: {ts, phase, picked_count, surprise_fired, failopen, llm_call_ms}
#
# Critical contract: this function NEVER blocks the cycle path. On any
# error (lock contention, unwritable file, missing jq, ...) it silently
# no-ops. Telemetry quality is sacrificed for cycle reliability.
#
# GPT plan-review fixes applied:
#  - C2: lock retry capped at 10 attempts × 1s = 10s max → then drop sample
#  - C3: picked_count uses `tr ' ' '\n' | grep -c` (was wrong tr pattern)
#  - I1: stale lockdir auto-cleanup if mtime > 30 seconds
#  - I2: rotation truncates .old (single rotation, no unbounded growth)
#  - I7: comment matches implementation (direct append under lock; no tmpfile)

: "${PP_ROUTER_METRICS_FILE:=${HOME}/.claude/cache/router-metrics.jsonl}"
: "${PP_ROUTER_METRICS_MAX_LINES:=5000}"

pp_router_metrics_emit() {
  # Defensive: never propagate a failure to the cycle path. Wrapping in
  # a subshell with set +e ensures we always return 0 even under bats's
  # set -e environment or if internal commands hiccup.
  (
    set +e
    local _signals="$1"
    [ -z "$_signals" ] && _signals='{}'
    local _picked="${2:-}"
    local _surprise="${3:-0}"
    local _failopen="${4:-0}"
    local _llm_ms="${5:-0}"

    command -v jq >/dev/null 2>&1 || exit 0
    local _dir
    _dir=$(dirname "$PP_ROUTER_METRICS_FILE" 2>/dev/null)
    [ -z "$_dir" ] && exit 0
    mkdir -p "$_dir" 2>/dev/null || exit 0
    [ -w "$_dir" ] || exit 0

    # Phase from signals (jq -r; defaults to "unknown" on parse failure).
    local _phase
    _phase=$(printf '%s' "$_signals" | jq -r '.phase // "unknown"' 2>/dev/null) || _phase="unknown"
    [ -z "$_phase" ] && _phase="unknown"

    # Count picked entries. GPT-C3: `tr ' \n' '\n\n'` was wrong (single-
    # quoted '\n' is literal two chars, not newline). Correct: normalize
    # delimiters to newline, then count lines with any non-whitespace char.
    local _picked_count=0
    if [ -n "$_picked" ]; then
      _picked_count=$(printf '%s' "$_picked" | tr ' ' '\n' | LC_ALL=C grep -c '^[^[:space:]]' 2>/dev/null) || _picked_count=0
      [ -z "$_picked_count" ] && _picked_count=0
    fi

    # Build JSONL line (compact, single-line).
    local _ts _line
    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || _ts="1970-01-01T00:00:00Z"
    _line=$(jq -n -c \
      --arg ts "$_ts" \
      --arg phase "$_phase" \
      --argjson picked_count "$_picked_count" \
      --argjson surprise_fired "$_surprise" \
      --argjson failopen "$_failopen" \
      --argjson llm_call_ms "$_llm_ms" \
      '{ts: $ts, phase: $phase, picked_count: $picked_count, surprise_fired: $surprise_fired, failopen: $failopen, llm_call_ms: $llm_call_ms}' \
      2>/dev/null) || _line=""
    [ -z "$_line" ] && exit 0

    # Bash 3.2-portable lock: mkdir is atomic across NFS too.
    # Stale-lock auto-cleanup: if .lock dir older than 60s the previous
    # writer probably crashed; reclaim. (GPT-R2-M4: bump threshold above
    # PP_ROUTER_TIMEOUT_S × retry_cap so a genuinely slow writer isn't
    # mid-flight when reclaimed.)
    local _lockdir="${PP_ROUTER_METRICS_FILE}.lock"
    if [ -d "$_lockdir" ]; then
      local _now _ltime
      _now=$(date +%s 2>/dev/null) || _now=""
      _ltime=$(stat -c %Y "$_lockdir" 2>/dev/null || stat -f %m "$_lockdir" 2>/dev/null) || _ltime=""
      if [ -n "$_now" ] && [ -n "$_ltime" ] && [ "$((_now - _ltime))" -gt 60 ]; then
        rmdir "$_lockdir" 2>/dev/null
      fi
    fi

    # Lock retry matches the project's established pattern in
    # lib/budget.sh:23-28 (250 × 0.02s = 5s worst case). 50 × 0.02s = 1s
    # is the right cycle-reliable balance: enough attempts for concurrent
    # writers to coordinate without blocking the cycle. (Code-reviewer
    # round-2 C1 + Debugger round-2 I1: telemetry caller is now
    # backgrounded in statusline.sh, so even this 1s worst case can't
    # block the analyst fan-out.)
    local _tries=0
    while ! mkdir "$_lockdir" 2>/dev/null; do
      _tries=$((_tries + 1))
      [ "$_tries" -ge 50 ] && exit 0
      sleep 0.02 2>/dev/null || sleep 1
    done

    # GPT-R2-C4: rotate BEFORE append (was append→mv which moved the
    # just-written line into .old). GPT-R3: use line count to match the
    # variable name PP_ROUTER_METRICS_MAX_LINES (was byte-estimate which
    # caused semantic drift). Cost: O(n) wc -l per call, but n is capped
    # at 5000 and we hold the lock anyway — negligible vs analyst calls.
    if [ -f "$PP_ROUTER_METRICS_FILE" ]; then
      local _count
      _count=$(wc -l < "$PP_ROUTER_METRICS_FILE" 2>/dev/null | tr -d ' ') || _count=0
      if [ -n "$_count" ] && [ "$_count" -ge "${PP_ROUTER_METRICS_MAX_LINES:-5000}" ]; then
        mv -f "$PP_ROUTER_METRICS_FILE" "${PP_ROUTER_METRICS_FILE}.old" 2>/dev/null
      fi
    fi

    # Append (direct, single-line, atomic on most POSIX FS for <PIPE_BUF bytes).
    printf '%s\n' "$_line" >> "$PP_ROUTER_METRICS_FILE" 2>/dev/null

    rmdir "$_lockdir" 2>/dev/null
    exit 0
  ) 2>/dev/null
  return 0
}
