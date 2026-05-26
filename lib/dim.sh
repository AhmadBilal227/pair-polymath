#!/usr/bin/env bash
# v0.5.3 — Developer Insights Module control plane.
#
# Owns: gate evaluator, state machine, state-file I/O.
# Reads: oar-labeled.jsonl (via lib/dim-stats.sh aggregator).
# Writes: dim-state.${sha8}.jsonl, dim-gate-last-eval.${sha8}.jsonl,
#         dim-last-eval-epoch.${sha8}.txt.
#
# All state files are per-project (sharded by project_root_sha8) to prevent
# one project's OAR accumulation from auto-activating DIM for another.
# Bash 3.2-portable: no mapfile, no ${var,,}, no flock.

[ "${_PP_DIM_SOURCED:-0}" = "1" ] && return 0

# Note: LC_ALL=C is applied INLINE on every awk/jq/sort/grep call below.
# We deliberately do NOT export LC_ALL at file top — that would mutate the
# caller's environment for the rest of the session.
_PP_DIM_SOURCED=1

# Lazy-load stats helpers
if [ "${_PP_DIM_STATS_SOURCED:-0}" != "1" ]; then
  _pp_dim_root="${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  # shellcheck disable=SC1091
  . "$_pp_dim_root/lib/dim-stats.sh"
fi

# Gate parameters (locked by spec).
PP_DIM_ALPHA="${PP_DIM_ALPHA:-0.05}"
PP_DIM_TARGET_LCB="${PP_DIM_TARGET_LCB:-0.05}"
PP_DIM_MIN_LENSES="${PP_DIM_MIN_LENSES:-3}"
PP_DIM_MIN_N="${PP_DIM_MIN_N:-250}"
PP_DIM_MIN_DISTINCT_DATES="${PP_DIM_MIN_DISTINCT_DATES:-5}"
PP_DIM_MIN_CALENDAR_DAYS="${PP_DIM_MIN_CALENDAR_DAYS:-7}"
PP_DIM_HOLDOUT_VALIDATION_DAYS="${PP_DIM_HOLDOUT_VALIDATION_DAYS:-7}"
PP_DIM_QUARANTINE_RECOVERY_DAYS="${PP_DIM_QUARANTINE_RECOVERY_DAYS:-14}"

# v0.5.6.1 FIX A2: sha8 format validation. The default arg `${1:-default}`
# accepts any string; a tainted caller passing `../etc` would write outside
# PP_STATE_DIR. Reject anything other than [a-zA-Z0-9_-] (the "default"
# sentinel + 8-hex sha8 prefixes both satisfy this); fall back to "default".
_pp_dim_validate_sha8() {
  local sha8="${1:-default}"
  case "$sha8" in
    ""|*[!a-zA-Z0-9_-]*) printf '%s' "default" ;;
    *) printf '%s' "$sha8" ;;
  esac
}

# pp_dim_state_file_path SHA8 → /path/to/dim-state.<sha8>.jsonl
pp_dim_state_file_path() {
  local sha8
  sha8=$(_pp_dim_validate_sha8 "${1:-default}")
  echo "${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/dim-state.${sha8}.jsonl"
}

# pp_dim_last_eval_path SHA8 → /path/to/dim-last-eval-epoch.<sha8>.txt
pp_dim_last_eval_path() {
  local sha8
  sha8=$(_pp_dim_validate_sha8 "${1:-default}")
  echo "${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/dim-last-eval-epoch.${sha8}.txt"
}

# pp_dim_gate_eval_path SHA8 → /path/to/dim-gate-last-eval.<sha8>.jsonl
pp_dim_gate_eval_path() {
  local sha8
  sha8=$(_pp_dim_validate_sha8 "${1:-default}")
  echo "${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/dim-gate-last-eval.${sha8}.jsonl"
}

# pp_dim_get_current_state SHA8 → current state (default: "monitoring")
# Reads the last line of dim-state.<sha8>.jsonl; jq-extracts .to.
pp_dim_get_current_state() {
  local f
  f=$(pp_dim_state_file_path "${1:-default}")
  [ -f "$f" ] || { echo "monitoring"; return 0; }
  local last
  last=$(tail -n 1 "$f" 2>/dev/null)
  [ -z "$last" ] && { echo "monitoring"; return 0; }
  local state
  state=$(printf '%s' "$last" | jq -r '.to // "monitoring"' 2>/dev/null)
  if [ -z "$state" ] || [ "$state" = "null" ]; then
    state="monitoring"
  fi
  echo "$state"
}

# v0.5.6.1 FIX B2: lazy-source the shared JSONL rotation helper. dim-state
# and dim-gate-last-eval are infrequent writers (max one transition per day
# per project) but a long-lived install can still grow them past sensible
# bounds. Cap rotates at PP_DIM_LOG_MAX_BYTES (default 1MB, smaller than
# kpi/router because writes here are sparse).
_pp_dim_load_rotator() {
  if ! type _pp_rotate_jsonl >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${_pp_dim_root:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/metrics.sh" 2>/dev/null || return 1
  fi
  return 0
}

_pp_dim_rotate_state_file() {
  local _f="$1"
  [ -n "$_f" ] || return 0
  local _max="${PP_DIM_LOG_MAX_BYTES:-1048576}"
  case "$_max" in (*[!0-9]*|"") _max=1048576 ;; esac
  _pp_dim_load_rotator && _pp_rotate_jsonl "$_f" "$_max" 2>/dev/null || true
}

# pp_dim_append_transition SHA8 FROM TO REASON SOURCE GATE_SNAPSHOT_JSON
# Atomically appends one transition row to dim-state.<sha8>.jsonl.
# SOURCE: "auto" | "operator_override" | "auto_recovery"
pp_dim_append_transition() {
  local sha8="${1:-default}" from="${2:-monitoring}" to="${3:-monitoring}"
  local reason="${4:-}" _src="${5:-auto}" gate_json="${6:-{\}}"
  local f
  f=$(pp_dim_state_file_path "$sha8")
  mkdir -p "$(dirname "$f")" 2>/dev/null
  # v0.5.6.1 FIX B2: rotate BEFORE append at 1MB cap.
  _pp_dim_rotate_state_file "$f"
  local ts row
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  row=$(jq -nc --arg ts "$ts" --arg from "$from" --arg to "$to" \
              --arg reason "$reason" --arg source "$_src" \
              --argjson gate_snapshot "$gate_json" \
    '{ts:$ts, from:$from, to:$to, reason:$reason, source:$source, gate_snapshot:$gate_snapshot}')
  printf '%s\n' "$row" >> "$f"
}

# pp_dim_evaluate_gate OAR_FILE PROJECT_SHA8
# Pure function: returns gate decision as JSON. Does not mutate state.
# Output: {qualifies, lenses_qualifying, per_lens: [...], evaluated_at,
#          calendar_span_days, calendar_days_floor}
pp_dim_evaluate_gate() {
  local oar="$1" sha8="${2:-default}"
  local rollup
  rollup=$(pp_dim_stats_per_lens_rollup "$oar" "$sha8")
  local gated
  gated=$(printf '%s' "$rollup" | jq -c '.gated')
  if [ "$gated" = "[]" ] || [ -z "$gated" ]; then
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{qualifies:false, lenses_qualifying:0, per_lens:[], evaluated_at:$ts}'
    return 0
  fi
  local gate
  gate=$(pp_dim_stats_composite_gate "$gated" \
           "$PP_DIM_ALPHA" "$PP_DIM_TARGET_LCB" \
           "$PP_DIM_MIN_LENSES" "$PP_DIM_MIN_N" "$PP_DIM_MIN_DISTINCT_DATES")
  # Global calendar floor: even when 3+ lenses each pass distinct_dates>=5,
  # the union of all qualifying-lens dates must span >= PP_DIM_MIN_CALENDAR_DAYS.
  # Compute the span from the OAR rows for this project. jq builtins differ
  # across platforms (gojq vs jq, macOS strptime quirks), so we pipe min/max
  # date strings to awk and do the day math with portable date logic.
  local span_days
  span_days=0
  if [ -f "$oar" ]; then
    local _date_bounds
    _date_bounds=$(LC_ALL=C jq -sr --arg sha8 "$sha8" '
      [.[] | select(.project_root_sha8 == $sha8) | (.inject_ts // "")[0:10] | select(. != "")]
      | unique
      | if length < 2 then "" else "\(min) \(max)" end
    ' "$oar" 2>/dev/null)
    if [ -n "$_date_bounds" ]; then
      local _d_min _d_max _epoch_min _epoch_max
      _d_min="${_date_bounds%% *}"
      _d_max="${_date_bounds##* }"
      _epoch_min=$(date -u -j -f "%Y-%m-%d" "$_d_min" +%s 2>/dev/null \
                   || date -u -d "$_d_min" +%s 2>/dev/null \
                   || echo "0")
      _epoch_max=$(date -u -j -f "%Y-%m-%d" "$_d_max" +%s 2>/dev/null \
                   || date -u -d "$_d_max" +%s 2>/dev/null \
                   || echo "0")
      if [ "$_epoch_min" -gt 0 ] 2>/dev/null && [ "$_epoch_max" -gt 0 ] 2>/dev/null; then
        span_days=$(( (_epoch_max - _epoch_min) / 86400 + 1 ))
      fi
    fi
  fi
  case "$span_days" in (*[!0-9]*|"") span_days=0 ;; esac
  if [ "$span_days" -lt "$PP_DIM_MIN_CALENDAR_DAYS" ] 2>/dev/null; then
    gate=$(printf '%s' "$gate" | jq -c \
      --argjson floor "$PP_DIM_MIN_CALENDAR_DAYS" \
      --argjson span "$span_days" \
      '.qualifies = false
       | .calendar_span_days = $span
       | .calendar_days_floor = $floor
       | .calendar_fail_reason = "global_calendar_span_below_floor"')
  else
    gate=$(printf '%s' "$gate" | jq -c \
      --argjson floor "$PP_DIM_MIN_CALENDAR_DAYS" \
      --argjson span "$span_days" \
      '.calendar_span_days = $span | .calendar_days_floor = $floor')
  fi
  printf '%s\n' "$gate" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {evaluated_at:$ts}'
}

# pp_dim_evaluate_gate_daily SHA8 [OAR_FILE]
# Public entry point. Once per UTC date, under mkdir lock:
#   1. Compute gate decision
#   2. Append forensic row to dim-gate-last-eval.<sha8>.jsonl
#   3. Apply state-machine transition if gate state changed
#   4. Update dim-last-eval-epoch.<sha8>.txt
pp_dim_evaluate_gate_daily() {
  local sha8="${1:-default}"
  local oar="${2:-${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/oar-labeled.jsonl}"
  # Gate 0: respect master enable flag
  [ "${PP_DIM_ENABLE:-1}" = "1" ] || return 0
  # v0.5.6.1 FIX B3: default-shard short-circuit. When sha8="default" AND
  # the on-disk OAR has no rows tagged with project_root_sha8=="default",
  # the rollup is guaranteed empty and the whole pipeline is wasted work.
  # Skip silently — saves the daily eval cost on machines where DIM is
  # installed globally but the user is currently outside a project root.
  if [ "$sha8" = "default" ]; then
    if ! [ -f "$oar" ] || ! LC_ALL=C grep -q '"project_root_sha8":"default"' "$oar" 2>/dev/null; then
      return 0
    fi
  fi
  # Gate 1: once-per-UTC-date
  local today
  today=$(date -u +%Y%m%d)
  local last_file
  last_file=$(pp_dim_last_eval_path "$sha8")
  if [ -f "$last_file" ]; then
    local last_epoch
    last_epoch=$(cat "$last_file" 2>/dev/null)
    if [ -n "$last_epoch" ] && [ "$last_epoch" -gt 0 ] 2>/dev/null; then
      local last_day
      last_day=$(date -u -r "$last_epoch" +%Y%m%d 2>/dev/null \
                 || date -u -d "@$last_epoch" +%Y%m%d 2>/dev/null \
                 || echo "")
      [ "$last_day" = "$today" ] && return 0
    fi
  fi
  # Gate 2: mkdir lock
  local lock="${PP_STATE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/state}/dim-eval-${sha8}.lock"
  mkdir -p "$(dirname "$lock")" 2>/dev/null
  if ! mkdir "$lock" 2>/dev/null; then
    return 0  # Another process is evaluating; bail.
  fi
  # Signal-only cleanup so a Ctrl-C / TERM never leaves a stale lock dir that
  # blocks tomorrow's eval. NOTE: do NOT add RETURN here — this function calls
  # nested functions (pp_dim_evaluate_gate, pp_dim_apply_transition, ...) and
  # under `set -T` (functrace, which bats enables) a function-scoped RETURN
  # trap fires on every nested return, releasing the lock mid-evaluation and
  # defeating the concurrency guard. Normal-exit cleanup is explicit below.
  # shellcheck disable=SC2064
  trap "rm -rf '$lock' 2>/dev/null; true" INT TERM
  # Double-checked locking: re-read last-eval inside the lock
  if [ -f "$last_file" ]; then
    local last_epoch2
    last_epoch2=$(cat "$last_file" 2>/dev/null)
    if [ -n "$last_epoch2" ] && [ "$last_epoch2" -gt 0 ] 2>/dev/null; then
      local last_day2
      last_day2=$(date -u -r "$last_epoch2" +%Y%m%d 2>/dev/null \
                  || date -u -d "@$last_epoch2" +%Y%m%d 2>/dev/null \
                  || echo "")
      if [ "$last_day2" = "$today" ]; then
        rm -rf "$lock" 2>/dev/null
        return 0
      fi
    fi
  fi
  # Evaluate gate
  local gate
  gate=$(pp_dim_evaluate_gate "$oar" "$sha8")
  # Append forensic row (v0.5.6.1 FIX B2: rotate before append)
  local eval_file
  eval_file=$(pp_dim_gate_eval_path "$sha8")
  mkdir -p "$(dirname "$eval_file")" 2>/dev/null
  _pp_dim_rotate_state_file "$eval_file"
  printf '%s\n' "$gate" >> "$eval_file"
  # Update last-eval epoch
  date +%s > "$last_file"
  # Apply state transition
  pp_dim_apply_transition "$sha8" "$gate"
  rm -rf "$lock" 2>/dev/null
  return 0
}

# pp_dim_apply_transition SHA8 GATE_JSON
# State machine: monitoring → gated → active → quarantine → monitoring.
# Read current state, decide next, append transition if changed.
pp_dim_apply_transition() {
  local sha8="$1" gate="$2"
  local cur next reason
  cur=$(pp_dim_get_current_state "$sha8")
  local qualifies
  qualifies=$(printf '%s' "$gate" | jq -r '.qualifies // false')
  next="$cur"
  reason=""
  case "$cur" in
    monitoring)
      if [ "$qualifies" = "true" ]; then
        next="gated"; reason="gate cleared; entering holdout validation window"
      fi
      ;;
    gated)
      # If the gate unqualifies during the holdout window, regress to
      # monitoring rather than getting stuck pending promotion forever.
      if [ "$qualifies" != "true" ]; then
        next="monitoring"; reason="gate regressed during holdout window"
      else
        # Check if 7d holdout validation window has elapsed
        local entered_at age_days
        entered_at=$(pp_dim_state_entered_at "$sha8" "gated")
        [ -n "$entered_at" ] || return 0
        age_days=$(pp_dim_days_since "$entered_at")
        if [ "$age_days" -ge "$PP_DIM_HOLDOUT_VALIDATION_DAYS" ]; then
          # Check for drift; if no drift, promote
          if pp_dim_holdout_no_drift "$sha8"; then
            next="active"; reason="holdout validation passed (${age_days}d, no drift)"
          fi
        fi
      fi
      ;;
    active)
      # Continuous drift surveillance
      if ! pp_dim_holdout_no_drift "$sha8"; then
        next="quarantine"; reason="post-activation drift detected"
      fi
      ;;
    quarantine)
      # Auto-recover after 14d clean window
      local entered_at age_days
      entered_at=$(pp_dim_state_entered_at "$sha8" "quarantine")
      [ -n "$entered_at" ] || return 0
      age_days=$(pp_dim_days_since "$entered_at")
      if [ "$age_days" -ge "$PP_DIM_QUARANTINE_RECOVERY_DAYS" ] && \
         pp_dim_holdout_no_drift "$sha8"; then
        next="monitoring"; reason="quarantine cleared after ${age_days}d clean window"
      fi
      ;;
  esac
  if [ "$next" != "$cur" ]; then
    pp_dim_append_transition "$sha8" "$cur" "$next" "$reason" "auto" "$gate"
  fi
}

# pp_dim_state_entered_at SHA8 STATE → ISO timestamp of LAST transition INTO STATE, or empty
pp_dim_state_entered_at() {
  local f
  f=$(pp_dim_state_file_path "$1")
  [ -f "$f" ] || return 0
  jq -r --arg s "$2" 'select(.to == $s) | .ts' "$f" 2>/dev/null | tail -n 1
}

# pp_dim_days_since ISO_TS → integer days (UTC, BSD/GNU date-portable)
pp_dim_days_since() {
  local ts="$1"
  [ -z "$ts" ] && { echo "0"; return; }
  local then_epoch now_epoch
  then_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
               || date -u -d "$ts" +%s 2>/dev/null \
               || echo "0")
  now_epoch=$(date -u +%s)
  echo $(( (now_epoch - then_epoch) / 86400 ))
}

# pp_dim_holdout_no_drift SHA8 → 0 (no drift) / 1 (drift)
# Compares holdout acted% vs gated acted% using pooled SE.
# Drift = |holdout_pct - gated_pct| > 2*SE. Returns 0 (no drift) if holdout_n < 20.
#
# v0.5.6.1 FIX A6: previously took a second $gate arg that the body ignored
# (it re-reads OAR fresh on every call). The unused parameter invited
# callers to plumb stale gate snapshots through; drop it.
pp_dim_holdout_no_drift() {
  local sha8="$1"
  local oar="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/oar-labeled.jsonl"
  local rollup
  rollup=$(pp_dim_stats_per_lens_rollup "$oar" "$sha8")
  local gated_s gated_n holdout_s holdout_n
  gated_s=$(printf '%s' "$rollup" | jq '[.gated[].s]   | add // 0')
  gated_n=$(printf '%s' "$rollup" | jq '[.gated[].n]   | add // 0')
  holdout_s=$(printf '%s' "$rollup" | jq '[.holdout[].s] | add // 0')
  holdout_n=$(printf '%s' "$rollup" | jq '[.holdout[].n] | add // 0')
  # Need at least 20 holdout rows for a meaningful SE check; otherwise default no-drift.
  [ "$holdout_n" -lt 20 ] && return 0
  LC_ALL=C awk -v gs="$gated_s" -v gn="$gated_n" -v hs="$holdout_s" -v hn="$holdout_n" 'BEGIN {
    if (gn == 0 || hn == 0) exit 0
    gp = gs / gn; hp = hs / hn
    pooled = (gs + hs) / (gn + hn)
    se = sqrt(pooled * (1 - pooled) * (1/gn + 1/hn))
    diff = gp - hp; if (diff < 0) diff = -diff
    if (se == 0) exit 0
    exit (diff > 2 * se) ? 1 : 0
  }'
}
