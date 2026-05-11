#!/usr/bin/env bash
# Pair Polymath — USD telemetry. Sourced by bin/statusline.sh.
# Lean v1 approach: end-of-cycle rollup. Calls are TYPE-counted during the
# cycle (planner / analyst / critique / inv / retry); at flush time we
# multiply by static avg-token assumptions and per-million prices.
#
# v0.3 will swap this for real per-call usage parsing via `llm --usage`.

# === Prices per 1M tokens (input | output) ===
# Edit in user.env to match your org's billing. Defaults reflect public
# pricing snapshots at v0.2 ship time; expect drift.
PP_PRICE_GPT_5_MINI_IN_PER_M="${PP_PRICE_GPT_5_MINI_IN_PER_M:-0.25}"
PP_PRICE_GPT_5_MINI_OUT_PER_M="${PP_PRICE_GPT_5_MINI_OUT_PER_M:-2.00}"
PP_PRICE_GPT_5_IN_PER_M="${PP_PRICE_GPT_5_IN_PER_M:-1.25}"
PP_PRICE_GPT_5_OUT_PER_M="${PP_PRICE_GPT_5_OUT_PER_M:-10.00}"
PP_PRICE_GPT_5_5_IN_PER_M="${PP_PRICE_GPT_5_5_IN_PER_M:-2.50}"
PP_PRICE_GPT_5_5_OUT_PER_M="${PP_PRICE_GPT_5_5_OUT_PER_M:-15.00}"

# === Avg-token assumptions per call type ===
PP_AVG_TOK_PLANNER_IN="${PP_AVG_TOK_PLANNER_IN:-800}"
PP_AVG_TOK_PLANNER_OUT="${PP_AVG_TOK_PLANNER_OUT:-50}"
PP_AVG_TOK_ANALYST_IN="${PP_AVG_TOK_ANALYST_IN:-2200}"
PP_AVG_TOK_ANALYST_OUT="${PP_AVG_TOK_ANALYST_OUT:-180}"
PP_AVG_TOK_CRITIQUE_IN="${PP_AVG_TOK_CRITIQUE_IN:-3500}"
PP_AVG_TOK_CRITIQUE_OUT="${PP_AVG_TOK_CRITIQUE_OUT:-500}"
PP_AVG_TOK_INV_IN="${PP_AVG_TOK_INV_IN:-1500}"
PP_AVG_TOK_INV_OUT="${PP_AVG_TOK_INV_OUT:-100}"
PP_AVG_TOK_RETRY_IN="${PP_AVG_TOK_RETRY_IN:-2500}"
PP_AVG_TOK_RETRY_OUT="${PP_AVG_TOK_RETRY_OUT:-180}"

# Default PP_CACHE_DIR if config.sh hasn't been sourced (e.g. unit tests).
PP_CACHE_DIR="${PP_CACHE_DIR:-${HOME}/.claude/cache}"
PP_METRICS_FILE="${PP_CACHE_DIR}/metrics.jsonl"
PP_METRICS_TMP_PREFIX="${PP_CACHE_DIR}/metrics-tmp"

# metrics_init SESSION_ID — set up a per-cycle tmp file
metrics_init() {
  local sid="${1:-default}"
  # Sanitize sid the same way statusline does (alphanumeric + ._-)
  sid=$(printf '%s' "$sid" | tr -cd 'a-zA-Z0-9._-' | cut -c1-64)
  [ -z "$sid" ] && sid="default"
  mkdir -p "$PP_CACHE_DIR" 2>/dev/null || true
  PP_METRICS_TMP="${PP_METRICS_TMP_PREFIX}-${sid}.txt"
  : > "$PP_METRICS_TMP"
}

# metrics_increment_call CALL_TYPE MODEL — record one call
# CALL_TYPE: planner | analyst | critique | inv | retry
# MODEL: gpt-5-mini | gpt-5 | gpt-5.5  (free-form OK; rollup matches on substrings)
metrics_increment_call() {
  local call_type="$1" model="$2"
  [ -z "${PP_METRICS_TMP:-}" ] && return 0
  # Sanitize call_type and model to single-line tokens to keep the tmp
  # format (one TSV row per call) robust against weird inputs.
  call_type=$(printf '%s' "$call_type" | tr -cd 'a-zA-Z0-9_-' | cut -c1-32)
  model=$(printf '%s' "$model" | tr -cd 'a-zA-Z0-9._-' | cut -c1-64)
  [ -z "$call_type" ] && return 0
  printf '%s\t%s\n' "$call_type" "$model" >> "$PP_METRICS_TMP" 2>/dev/null || true
}

# _metrics_usd_for_call CALL_TYPE MODEL → prints USD (6-decimal float)
# Returns 0 USD for unknown call types (so they don't blow up the rollup).
_metrics_usd_for_call() {
  local call_type="$1" model="$2"
  local in_per_m out_per_m tok_in tok_out
  case "$call_type" in
    planner)  tok_in="$PP_AVG_TOK_PLANNER_IN";  tok_out="$PP_AVG_TOK_PLANNER_OUT" ;;
    analyst)  tok_in="$PP_AVG_TOK_ANALYST_IN";  tok_out="$PP_AVG_TOK_ANALYST_OUT" ;;
    critique) tok_in="$PP_AVG_TOK_CRITIQUE_IN"; tok_out="$PP_AVG_TOK_CRITIQUE_OUT" ;;
    inv)      tok_in="$PP_AVG_TOK_INV_IN";      tok_out="$PP_AVG_TOK_INV_OUT" ;;
    retry)    tok_in="$PP_AVG_TOK_RETRY_IN";    tok_out="$PP_AVG_TOK_RETRY_OUT" ;;
    *) printf '0.000000'; return ;;
  esac
  # Order matters: gpt-5-mini must match before gpt-5, and gpt-5.5 before
  # gpt-5 (because gpt-5* matches gpt-5.5 too). Case statement evaluates
  # top-to-bottom, so list most-specific first.
  case "$model" in
    *gpt-5-mini*) in_per_m="$PP_PRICE_GPT_5_MINI_IN_PER_M";  out_per_m="$PP_PRICE_GPT_5_MINI_OUT_PER_M" ;;
    *gpt-5.5*)    in_per_m="$PP_PRICE_GPT_5_5_IN_PER_M";     out_per_m="$PP_PRICE_GPT_5_5_OUT_PER_M" ;;
    *gpt-5*)      in_per_m="$PP_PRICE_GPT_5_IN_PER_M";       out_per_m="$PP_PRICE_GPT_5_OUT_PER_M" ;;
    *)            in_per_m=0; out_per_m=0 ;;
  esac
  awk -v ti="$tok_in" -v to="$tok_out" -v ip="$in_per_m" -v op="$out_per_m" \
    'BEGIN { printf "%.6f", (ti / 1000000.0) * ip + (to / 1000000.0) * op }'
}

# metrics_flush_cycle SESSION_ID — roll up tmp into a single JSONL entry
# Idempotent: missing/empty tmp file → no-op (returns 0).
metrics_flush_cycle() {
  local sid="${1:-default}"
  [ -z "${PP_METRICS_TMP:-}" ] && return 0
  if [ ! -s "$PP_METRICS_TMP" ]; then
    rm -f "$PP_METRICS_TMP" 2>/dev/null
    return 0
  fi

  mkdir -p "$(dirname "$PP_METRICS_FILE")" 2>/dev/null || true

  # Compute total USD by summing per-row USD values. awk float math.
  local total_usd
  total_usd=$(while IFS=$'\t' read -r call_type model; do
    [ -z "$call_type" ] && continue
    _metrics_usd_for_call "$call_type" "$model"
    printf '\n'
  done < "$PP_METRICS_TMP" | awk '{ s += $1 } END { printf "%.6f", (s + 0) }')

  local calls
  calls=$(wc -l < "$PP_METRICS_TMP" | tr -d ' ')

  # By-type counts as a JSON object. Build via jq -Rn from "name\tcount" lines.
  local by_type
  by_type=$(awk -F'\t' 'NF>=1 && $1!="" {print $1}' "$PP_METRICS_TMP" \
    | sort | uniq -c \
    | awk '{print $2"\t"$1}' \
    | jq -Rn '[inputs | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}' 2>/dev/null)
  [ -z "$by_type" ] && by_type='{}'

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Build the JSONL entry in a tmp file in the SAME directory, then append.
  # Same-dir mktemp keeps the rename atomic on the same filesystem.
  local entry_tmp
  entry_tmp=$(mktemp "${PP_METRICS_FILE}.entry.XXXXXX") || {
    rm -f "$PP_METRICS_TMP" 2>/dev/null
    return 1
  }
  jq -cn \
    --arg ts "$ts" \
    --arg sid "$sid" \
    --argjson calls "$calls" \
    --argjson usd "$total_usd" \
    --argjson by_type "$by_type" \
    '{ts:$ts, session:$sid, calls:$calls, usd_est:$usd, by_type:$by_type}' \
    > "$entry_tmp" 2>/dev/null

  if [ -s "$entry_tmp" ]; then
    cat "$entry_tmp" >> "$PP_METRICS_FILE"
  fi
  rm -f "$entry_tmp" "$PP_METRICS_TMP" 2>/dev/null
  return 0
}
