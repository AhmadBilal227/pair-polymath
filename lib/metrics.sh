#!/usr/bin/env bash
# Pair Polymath — USD telemetry. Sourced by bin/statusline.sh.
# Lean v1 approach: end-of-cycle rollup. Calls are TYPE-counted during the
# cycle (planner / analyst / critique / inv / retry); at flush time we
# multiply by static avg-token assumptions and per-million prices.
#
# v0.3 will swap this for real per-call usage parsing via `llm --usage`.
#
# Locale-independent numeric formatting (review fix R2-H1): bash's awk + jq
# pipeline breaks under locales with comma as decimal separator (de_DE,
# fr_FR, sv_SE, etc.) because awk's `printf "%.6f"` honors LC_NUMERIC and
# produces "0,000910" which jq then rejects as invalid JSON, silently
# dropping the entire metrics row. We pin LC_ALL=C around every awk call
# that does numeric formatting.

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

# _pp_awk — wrapper that pins locale to C so awk's printf formats numbers
# with `.` decimals regardless of the user's LC_NUMERIC / LC_ALL settings
# (review fix R2-H1). Use this for any awk invocation that emits numeric
# output meant to be parsed downstream by jq, bash arithmetic, etc.
_pp_awk() {
  LC_ALL=C awk "$@"
}

# metrics_init SESSION_ID — set up a per-cycle tmp file.
#
# Recovery semantics (review fix R2-M1): if a previous cycle crashed
# mid-run (SIGTERM, kill, OOM) and left a non-empty tmp file behind, flush
# it FIRST before truncating. Otherwise we'd silently throw away the
# pending cycle's cost data. metrics_flush_cycle is idempotent on missing
# tmp so this never doubles up.
metrics_init() {
  local sid="${1:-default}"
  # Sanitize sid the same way statusline does (alphanumeric + ._-)
  sid=$(printf '%s' "$sid" | tr -cd 'a-zA-Z0-9._-' | cut -c1-64)
  [ -z "$sid" ] && sid="default"
  mkdir -p "$PP_CACHE_DIR" 2>/dev/null || true
  PP_METRICS_TMP="${PP_METRICS_TMP_PREFIX}-${sid}.txt"
  # Recover from a crashed prior cycle by flushing its pending data
  # before we start a new cycle on the same session id.
  if [ -s "$PP_METRICS_TMP" ]; then
    metrics_flush_cycle "$sid"
  fi
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
#
# Locale (review fix R2-H1): uses _pp_awk so the output always uses `.` as
# decimal separator regardless of $LC_NUMERIC / $LC_ALL.
#
# Unknown models (review fix R2-H3): models that don't match a pricing
# pattern (gpt-4o, claude-*, local-llm, typos) used to silently price at
# $0. Now we emit a one-time stderr warning per (session × model) via a
# tracker file in $PP_CACHE_DIR. The JSONL entry is still produced (usd
# component for those calls is 0), so the user sees they ran calls but
# weren't billed for them, and can add prices to user.env.
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
    *)
      # Rate-limit the warning to once per (session × model) so we don't
      # spam stderr if the same unknown model is called dozens of times
      # per cycle. The marker file is wiped when PP_CACHE_DIR is.
      local safe_model warn_marker
      safe_model=$(printf '%s' "$model" | tr -cd 'a-zA-Z0-9._-' | cut -c1-64)
      warn_marker="${PP_CACHE_DIR}/.metrics-unknown-${safe_model}.warned"
      if [ -n "$model" ] && [ ! -f "$warn_marker" ]; then
        printf 'lib/metrics.sh: unknown model "%s" — billing as $0. Set PP_PRICE_* in user.env to track.\n' "$model" >&2
        : > "$warn_marker" 2>/dev/null || true
      fi
      in_per_m=0; out_per_m=0
      ;;
  esac
  _pp_awk -v ti="$tok_in" -v to="$tok_out" -v ip="$in_per_m" -v op="$out_per_m" \
    'BEGIN { printf "%.6f", (ti / 1000000.0) * ip + (to / 1000000.0) * op }'
}

# metrics_flush_cycle SESSION_ID — roll up tmp into a single JSONL entry
# Idempotent: missing/empty tmp file → no-op (returns 0).
#
# JSONL schema (review fix R2-H2):
#   {ts, session, calls, usd_est, by_type, by_type_usd}
# `by_type_usd` is new in round-2: it stores summed USD per call type so
# `polymath cost --by-lens` can report real cost breakdown instead of just
# raw call counts. Older entries lacking the field display as 0 USD via
# the // fallback in the CLI.
metrics_flush_cycle() {
  local sid="${1:-default}"
  [ -z "${PP_METRICS_TMP:-}" ] && return 0
  if [ ! -s "$PP_METRICS_TMP" ]; then
    rm -f "$PP_METRICS_TMP" 2>/dev/null
    return 0
  fi

  mkdir -p "$(dirname "$PP_METRICS_FILE")" 2>/dev/null || true

  # Compute total USD by summing per-row USD values. Pin LC_ALL=C so
  # awk's printf emits `.` decimals regardless of system locale
  # (review fix R2-H1) — otherwise the resulting string fails jq parsing
  # under locales like de_DE.UTF-8 and the whole row is silently dropped.
  local total_usd
  total_usd=$(while IFS=$'\t' read -r call_type model; do
    [ -z "$call_type" ] && continue
    _metrics_usd_for_call "$call_type" "$model"
    printf '\n'
  done < "$PP_METRICS_TMP" | _pp_awk '{ s += $1 } END { printf "%.6f", (s + 0) }')

  local calls
  calls=$(wc -l < "$PP_METRICS_TMP" | tr -d ' ')

  # By-type counts as a JSON object. Build via jq -Rn from "name\tcount" lines.
  local by_type
  by_type=$(awk -F'\t' 'NF>=1 && $1!="" {print $1}' "$PP_METRICS_TMP" \
    | sort | uniq -c \
    | awk '{print $2"\t"$1}' \
    | jq -Rn '[inputs | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}' 2>/dev/null)
  [ -z "$by_type" ] && by_type='{}'

  # By-type USD (review fix R2-H2): sum USD per call type. Iterate each
  # row, look up its USD via the same pricing helper, and accumulate into
  # an associative-array-like TSV that jq turns into a JSON object. This
  # lets `polymath cost --by-lens` show real per-type spend instead of
  # interpreting jq `add` as numeric sum (it isn't — see PR #10 R2 review).
  local by_type_usd_tsv
  by_type_usd_tsv=$(
    while IFS=$'\t' read -r call_type model; do
      [ -z "$call_type" ] && continue
      printf '%s\t%s\n' "$call_type" "$(_metrics_usd_for_call "$call_type" "$model")"
    done < "$PP_METRICS_TMP" \
    | _pp_awk -F'\t' '{ s[$1] += $2 } END { for (k in s) printf "%s\t%.6f\n", k, s[k] }'
  )
  local by_type_usd
  if [ -n "$by_type_usd_tsv" ]; then
    by_type_usd=$(printf '%s\n' "$by_type_usd_tsv" \
      | jq -Rn '[inputs | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}' 2>/dev/null)
  fi
  [ -z "$by_type_usd" ] && by_type_usd='{}'

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
    --argjson by_type_usd "$by_type_usd" \
    '{ts:$ts, session:$sid, calls:$calls, usd_est:$usd, by_type:$by_type, by_type_usd:$by_type_usd}' \
    > "$entry_tmp" 2>/dev/null

  if [ -s "$entry_tmp" ]; then
    cat "$entry_tmp" >> "$PP_METRICS_FILE"
  fi
  rm -f "$entry_tmp" "$PP_METRICS_TMP" 2>/dev/null
  return 0
}
