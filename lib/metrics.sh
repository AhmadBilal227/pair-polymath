#!/usr/bin/env bash
# I4 (v0.5.1): new JSONL telemetry logs (kpi-cycle.jsonl) must be owner-only.
# umask 077 here matches the established v0.4.2 invariant pattern other libs
# use — every file this lib creates inherits 0600. Set before any file op.
umask 077

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
# Round-3 fix R3-PR10-4: serialize appends to metrics.jsonl. Two parallel
# cycles writing to the same file via `cat >>` can interleave bytes
# mid-line and corrupt JSONL. Mirror the mkdir-lock pattern from
# lib/budget.sh.
PP_METRICS_LOCK="${PP_METRICS_FILE}.lock"
# Round-3 fix R3-PR10-6: unknown-model warnings used to go to stderr,
# which in the cycle subshell is redirected to /dev/null — the user
# never saw them. We persist warnings to a log file so `polymath cost`
# can surface them in its output.
PP_METRICS_WARN_LOG="${PP_CACHE_DIR}/metrics-warnings.log"

# _pp_awk — wrapper that pins locale to C so awk's printf formats numbers
# with `.` decimals regardless of the user's LC_NUMERIC / LC_ALL settings
# (review fix R2-H1). Use this for any awk invocation that emits numeric
# output meant to be parsed downstream by jq, bash arithmetic, etc.
_pp_awk() {
  LC_ALL=C awk "$@"
}

# _pp_metrics_acquire / _pp_metrics_release — atomic append lock for
# metrics.jsonl (review fix R3-PR10-4). mkdir is atomic on every POSIX
# filesystem; sleep 0.02 × 250 attempts ≈ 5s timeout. Pattern matches
# lib/budget.sh's _pp_budget_acquire — single shared helper would be
# nice but would create a sourcing dependency we don't want here.
_pp_metrics_acquire() {
  mkdir -p "$(dirname "$PP_METRICS_LOCK")" 2>/dev/null || true
  local attempts=0
  while ! mkdir "$PP_METRICS_LOCK" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -gt 250 ] && return 1
    sleep 0.02 2>/dev/null || sleep 1
  done
  return 0
}

_pp_metrics_release() {
  rmdir "$PP_METRICS_LOCK" 2>/dev/null
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
      #
      # Round-3 fix R3-PR10-6: in addition to stderr (which the cycle
      # subshell discards), persist the warning to PP_METRICS_WARN_LOG so
      # `polymath cost` can surface it. A v0.3 issue is tracked for
      # user-configurable per-model prices (R3-PR10-5).
      local safe_model warn_marker warn_ts
      safe_model=$(printf '%s' "$model" | tr -cd 'a-zA-Z0-9._-' | cut -c1-64)
      warn_marker="${PP_CACHE_DIR}/.metrics-unknown-${safe_model}.warned"
      if [ -n "$model" ] && [ ! -f "$warn_marker" ]; then
        printf 'lib/metrics.sh: unknown model "%s" — billing as $0. Set PP_PRICE_* in user.env to track.\n' "$model" >&2
        warn_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        mkdir -p "$(dirname "$PP_METRICS_WARN_LOG")" 2>/dev/null || true
        printf '%s\tunknown model %s — billing as $0; configure via user.env\n' \
          "$warn_ts" "$model" >> "$PP_METRICS_WARN_LOG" 2>/dev/null || true
        : > "$warn_marker" 2>/dev/null || true
      fi
      in_per_m=0; out_per_m=0
      ;;
  esac
  _pp_awk -v ti="$tok_in" -v to="$tok_out" -v ip="$in_per_m" -v op="$out_per_m" \
    'BEGIN { printf "%.6f", (ti / 1000000.0) * ip + (to / 1000000.0) * op }'
}

# pp_metrics_estimate_retry_usd MODEL
# Stdout: USD estimate for one retry call at this model tier.
# Uses existing PP_AVG_TOK_RETRY_IN/OUT + price knobs.
pp_metrics_estimate_retry_usd() {
  local _model="${1:?model required}"
  local _in="${PP_AVG_TOK_RETRY_IN:-2500}"
  local _out="${PP_AVG_TOK_RETRY_OUT:-180}"
  local _price_in _price_out
  case "$_model" in
    *gpt-5-mini*)   _price_in="${PP_PRICE_GPT_5_MINI_IN_PER_M:-0.25}"
                    _price_out="${PP_PRICE_GPT_5_MINI_OUT_PER_M:-2.00}" ;;
    *gpt-5.5*|*gpt-5-5*) _price_in="${PP_PRICE_GPT_5_5_IN_PER_M:-2.50}"
                         _price_out="${PP_PRICE_GPT_5_5_OUT_PER_M:-15.00}" ;;
    *gpt-5*)        _price_in="${PP_PRICE_GPT_5_IN_PER_M:-1.25}"
                    _price_out="${PP_PRICE_GPT_5_OUT_PER_M:-10.00}" ;;
    *)              _price_in=0.5; _price_out=4.0 ;;
  esac
  LC_ALL=C awk -v i="$_in" -v o="$_out" -v pi="$_price_in" -v po="$_price_out" \
    'BEGIN { printf "%.6f", (i*pi + o*po) / 1000000.0 }'
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
  #
  # Round-3 fix R3-PR10-3: previous version removed PP_METRICS_TMP
  # UNCONDITIONALLY after jq ran. If jq failed (OOM, missing binary,
  # corrupted argjson) the cycle's call data was permanently lost. Now:
  # if jq fails OR produces an empty entry, preserve PP_METRICS_TMP so
  # the next metrics_init recovery path can retry, and return non-zero.
  local entry_tmp
  entry_tmp=$(mktemp "${PP_METRICS_FILE}.entry.XXXXXX") || {
    printf 'metrics_flush_cycle: mktemp failed; tmp preserved at %s for next-init recovery\n' \
      "$PP_METRICS_TMP" >&2
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
  local jq_rc=$?

  if [ "$jq_rc" -ne 0 ] || [ ! -s "$entry_tmp" ]; then
    rm -f "$entry_tmp" 2>/dev/null
    printf 'metrics_flush_cycle: jq build failed (rc=%d); tmp preserved at %s for next-init recovery\n' \
      "$jq_rc" "$PP_METRICS_TMP" >&2
    return 1
  fi

  # Round-3 fix R3-PR10-4: serialize the append. Two cycles writing
  # concurrently via `cat >>` can interleave bytes mid-line. On lock
  # timeout, preserve tmp (don't block the cycle) and surface to stderr.
  if ! _pp_metrics_acquire; then
    rm -f "$entry_tmp" 2>/dev/null
    printf 'metrics_flush_cycle: append-lock timeout; tmp preserved at %s for next-init recovery\n' \
      "$PP_METRICS_TMP" >&2
    return 1
  fi
  cat "$entry_tmp" >> "$PP_METRICS_FILE"
  _pp_metrics_release
  rm -f "$entry_tmp" "$PP_METRICS_TMP" 2>/dev/null
  return 0
}

# === Privacy log (P3.3) =====================================================
# pp_write_privacy_log SESSION TRANSCRIPT_TAIL GROUNDED PLANNER_FILE \
#                      LENS_COUNT ANALYST_MODEL CRITIQUE_MODEL
#
# Writes a single overwriting JSON file at $PP_CACHE_DIR/last-cycle-payload.json
# showing what THIS cycle is about to send to OpenAI. Lets users verify the
# README "what leaves your machine" claim with their own eyes.
#
# NOT an archive — overwritten every cycle. NOT the response — only the
# OUTGOING payload preview. Atomic tmp+mv so a concurrent reader never sees
# half-written JSON.
#
# Empty/missing inputs are tolerated (defensive): we still emit a valid JSON
# file with 0-byte sizes and empty previews. Callers don't need to guard.
pp_write_privacy_log() {
  local session="${1:-default}"
  local transcript_tail="${2:-}"
  local grounded="${3:-}"
  local planner_file="${4:-<none>}"
  local lens_count="${5:-0}"
  local analyst_model="${6:-}"
  local critique_model="${7:-}"

  # Cache dir resolution: honor PP_CACHE_DIR > CLAUDE_DIR/cache > HOME/.claude/cache.
  # Must match `polymath status`'s reader resolution exactly (GPT R2 MEDIUM-3).
  local cache_dir="${PP_CACHE_DIR:-${CLAUDE_DIR:-${HOME}/.claude}/cache}"
  mkdir -p "$cache_dir" 2>/dev/null || return 1
  # Cache dir is owner-only. The file inside may include transcript previews
  # that contain user-pasted secrets — default umask 022 would publish them
  # world-readable. Enforce 0700 on the dir + 0600 on the file (GPT R2 HIGH-1).
  chmod 700 "$cache_dir" 2>/dev/null || true
  local out="${cache_dir}/last-cycle-payload.json"

  # First-500-char previews. Bash substring expansion is safe on empty.
  local transcript_preview="${transcript_tail:0:500}"
  local grounded_preview="${grounded:0:500}"
  # Byte counts via wc -c (not ${#var} — that counts CHARS, undercounts in
  # multibyte locales). LC_ALL=C forces byte-oriented counting (GPT R2 MED-4).
  local transcript_bytes grounded_bytes
  transcript_bytes=$(printf '%s' "$transcript_tail" | LC_ALL=C wc -c | tr -d ' ')
  grounded_bytes=$(printf '%s' "$grounded" | LC_ALL=C wc -c | tr -d ' ')

  # Normalize lens_count to integer; jq --argjson is strict and a non-numeric
  # string would fail the whole write.
  case "$lens_count" in
    ''|*[!0-9]*) lens_count=0 ;;
  esac

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Unique tmp path per writer — fixed "${out}.tmp" was racy across concurrent
  # statusline cycles. mktemp gives each writer its own file before atomic
  # rename onto the canonical path (GPT R2 HIGH-2).
  local _pp_priv_tmp
  _pp_priv_tmp=$(mktemp "${out}.XXXXXX" 2>/dev/null) || return 1

  jq -n \
    --arg ts "$ts" \
    --arg session "$session" \
    --arg planner_file "${planner_file:-<none>}" \
    --arg analyst_model "${analyst_model:-}" \
    --arg critique_model "${critique_model:-}" \
    --argjson lens_count "$lens_count" \
    --argjson transcript_bytes "$transcript_bytes" \
    --arg transcript_preview "$transcript_preview" \
    --argjson grounded_bytes "$grounded_bytes" \
    --arg grounded_preview "$grounded_preview" \
    '{
      ts: $ts,
      session: $session,
      cycle_summary: {
        lens_count: $lens_count,
        analyst_model: $analyst_model,
        critique_model: $critique_model,
        planner_picked_file: $planner_file
      },
      payload_sizes_bytes: {
        transcript_tail: $transcript_bytes,
        grounded_facts: $grounded_bytes
      },
      payload_previews: {
        transcript_first_500_chars: $transcript_preview,
        grounded_first_500_chars: $grounded_preview
      },
      note: "This file shows what THIS machine sent to OpenAI in the most recent cycle. Overwritten each cycle (no history). See docs/security.md for the full threat model."
    }' > "$_pp_priv_tmp" 2>/dev/null || {
      rm -f "$_pp_priv_tmp" 2>/dev/null
      return 1
    }

  [ -s "$_pp_priv_tmp" ] || { rm -f "$_pp_priv_tmp" 2>/dev/null; return 1; }
  # Restrict file mode BEFORE rename so concurrent readers can't catch a brief
  # world-readable window (defense in depth on top of dir chmod above).
  chmod 600 "$_pp_priv_tmp" 2>/dev/null || true
  mv "$_pp_priv_tmp" "$out" 2>/dev/null || { rm -f "$_pp_priv_tmp" 2>/dev/null; return 1; }
  chmod 600 "$out" 2>/dev/null || true
  return 0
}

# === v0.5.1 shared JSONL rotation helper ======================================
# _pp_rotate_jsonl FILE MAX_BYTES
#
# I3 (v0.5.1): pp_retry_log_shadow and pp_kpi_emit_cycle each used to do an
# unlocked check-size → mv → append. Under parallel lens fan-out two writers
# could both pass the size check and one mv could land mid-append of the
# other, producing torn JSONL. This single shared helper wraps the rotation
# decision (size check + mv) in the budget.sh-style mkdir-lock so exactly one
# writer rotates. Callers still append after calling this — the append itself
# is a single `printf >>` which is atomic for short lines on POSIX.
#
# Fails open: lock timeout or any error → return 0 (caller proceeds to append
# without rotating). Telemetry must never block the cycle.
_pp_rotate_jsonl() {
  local _file="${1:-}"
  local _max="${2:-10485760}"
  [ -n "$_file" ] || return 0
  case "$_max" in ''|*[!0-9]*) _max=10485760 ;; esac
  [ -f "$_file" ] || return 0
  local _lock="${_file}.rotate.lock"
  local _attempts=0
  while ! mkdir "$_lock" 2>/dev/null; do
    _attempts=$((_attempts + 1))
    # R5: stale-lock recovery. A SIGKILL between mkdir and rmdir would
    # otherwise orphan the lock dir permanently → every future cycle
    # spins the retry loop, gives up, and the JSONL grows unbounded past
    # the rotation cap. After 10 spins (~200ms), check the lock dir's
    # age via the project's pre-probed stat flavor (bin/polymath:29); if
    # older than ~60s no live writer holds it, so force-remove and retry.
    if [ "$_attempts" -eq 10 ]; then
      local _lock_age=0 _lock_mtime=0
      case "${_PP_STAT_FLAVOR:-}" in
        bsd) _lock_mtime=$(stat -f %m "$_lock" 2>/dev/null) ;;
        gnu) _lock_mtime=$(stat -c %Y "$_lock" 2>/dev/null) ;;
        *)
          # Same probe-order rationale as hooks/session-end.sh: BSD
          # `stat -f` on GNU Linux exits 0 with garbage (mount-point
          # string), so try GNU first + validate numeric, fall back
          # to BSD only if GNU produced nothing usable.
          _lock_mtime=$(stat -c %Y "$_lock" 2>/dev/null)
          case "$_lock_mtime" in ''|*[!0-9]*) _lock_mtime="" ;; esac
          [ -z "$_lock_mtime" ] && _lock_mtime=$(stat -f %m "$_lock" 2>/dev/null)
          ;;
      esac
      case "$_lock_mtime" in ''|*[!0-9]*) _lock_mtime=0 ;; esac
      _lock_age=$(( $(date +%s 2>/dev/null || echo 0) - _lock_mtime ))
      if [ "$_lock_age" -gt 60 ]; then
        rm -rf "$_lock" 2>/dev/null || true
        continue
      fi
    fi
    [ "$_attempts" -gt 100 ] && return 0
    sleep 0.02 2>/dev/null || sleep 1
  done
  # Re-check size INSIDE the lock — another writer may have just rotated.
  local _size
  _size=$(wc -c < "$_file" 2>/dev/null | tr -d ' ')
  if [ "${_size:-0}" -ge "$_max" ]; then
    mv "$_file" "${_file}.1" 2>/dev/null || true
  fi
  rmdir "$_lock" 2>/dev/null || true
  return 0
}

# === v0.5.1 KPI cycle emitter =================================================
# pp_kpi_emit_cycle JSON_BLOB
#
# Appends one JSON line to kpi-cycle.jsonl. Caller is responsible for shape;
# this function is a pure transport (no schema validation — keeps the emitter
# cheap and lets callers evolve the schema without coordinated changes here).
#
# Activation rules (in order):
#   1. PP_KPI_FORCE_DISABLE=1   → always skip (kill switch).
#   2. PP_KPI_ENABLE=1          → emit.
#   3. PP_RETRY_ROUTER_ENABLE=1 → emit (router needs the data to measure SLOs).
#   4. PP_RETRY_ROUTER_SHADOW=1 → emit (shadow mode is the SLO probe phase).
#   5. otherwise                → skip.
#
# Rotation: at PP_LOG_MAX_BYTES, rename file → file.1 (single retention slot,
# matching pp_retry_log_shadow's policy) via the shared _pp_rotate_jsonl
# mkdir-lock helper (I3). Failures are silent — telemetry must never block.
pp_kpi_emit_cycle() {
  [ "${PP_KPI_FORCE_DISABLE:-0}" = "1" ] && return 0
  local _enabled=0
  [ "${PP_KPI_ENABLE:-0}" = "1" ] && _enabled=1
  [ "${PP_RETRY_ROUTER_ENABLE:-0}" = "1" ] && _enabled=1
  [ "${PP_RETRY_ROUTER_SHADOW:-0}" = "1" ] && _enabled=1
  [ "$_enabled" = "0" ] && return 0
  local _blob="${1:-}"
  [ -z "$_blob" ] && return 0
  local _file="${PP_CACHE_DIR:-$HOME/.claude/cache}/kpi-cycle.jsonl"
  local _max="${PP_LOG_MAX_BYTES:-10485760}"
  case "$_max" in ''|*[!0-9]*) _max=10485760 ;; esac
  mkdir -p "$(dirname "$_file")" 2>/dev/null || return 0
  _pp_rotate_jsonl "$_file" "$_max"
  printf '%s\n' "$_blob" >> "$_file" 2>/dev/null || true
}

# === v0.5.1.1 Task 12 (Stage C): per-lens KPI accumulators ==================
# pp_kpi_emit_cycle stays pure transport; this helper just clamps the
# would_be_ineligible_count to [0, PASS_COUNT] so caller bugs can't corrupt
# the stream. Overflow surfaces as "100% PASS at risk" — doctor #22 catches
# the upstream cause separately.
#
# When PP_LENS_GATES_TELEMETRY=1, the statusline KPI emitter merges a
# `by_lens` sub-object (per-lens-per-cycle counts) into the v1 KPI blob and
# bumps `schema_version` to 2. The 7 fields per lens:
#   eligible_count               — 1 if lens eligible this cycle (Stage D)
#   dispatched_count             — 1 if lens was in the router's pick list
#   silent_count_by_reason       — {no_eligible_surface, persona_silent} ∈ {0,1}
#   pass_count                   — 1 if critique PASS this cycle
#   drop_count                   — 1 if critique DROP this cycle
#   drift_count                  — 1 if prompt-side != validator-side sha8
#   would_be_ineligible_count    — 1 if PASS AND shadow eligibility = false
# All seven default to 0 when the upstream marker file is missing — Stage D
# can land later without breaking the schema.
pp_kpi_lens_count_would_be_ineligible() {
  local _pass="${1:-0}" _wbi="${2:-0}"
  case "$_pass" in ''|*[!0-9]*) _pass=0 ;; esac
  case "$_wbi" in ''|*[!0-9]*) _wbi=0 ;; esac
  if [ "$_wbi" -gt "$_pass" ]; then
    _wbi="$_pass"
  fi
  printf '%s' "$_wbi"
}

# === v0.5.1 p95 computation ===================================================
# pp_kpi_compute_p95 FIELD WINDOW_HOURS
# Stdout: p95 of the named numeric field across kpi-cycle.jsonl rows whose
#   ts falls within the last WINDOW_HOURS. Also reads the rotated .1 file so
#   the window isn't lost right after a rotation.
#
# Pure jq + awk, bash-3.2-portable. Used by:
#   - auto-rollback's pp_rollback_check_and_engage (SLO p95 of retry_usd)
#   - `polymath kpi` (p95 of retry_usd, replacing the plain average)
#
# Method: nearest-rank p95 — sort ascending, pick index ceil(0.95*n). Empty
# dataset → prints 0. Fails open: any error → prints 0.
pp_kpi_compute_p95() {
  local _field="${1:-}"
  local _window_h="${2:-24}"
  [ -n "$_field" ] || { printf '0'; return 0; }
  case "$_window_h" in ''|*[!0-9]*) _window_h=24 ;; esac
  local _file="${PP_CACHE_DIR:-$HOME/.claude/cache}/kpi-cycle.jsonl"
  local _now _cutoff
  _now=$(date +%s 2>/dev/null) || _now=0
  _cutoff=$(( _now - _window_h * 3600 ))
  # Concatenate current + rotated file (rotated first = older). Read
  # line-oriented via `jq -R fromjson?` so a single torn write (e.g. from a
  # pre-R5 crash) skips one line instead of voiding the whole dataset
  # (R6 — `jq -s` over a torn file errors out → empty _vals → silent p95=0).
  # R1: exclude eligible:0 rows (skipped cycles) so a day of idle zero-rows
  # can't dilute the SLO percentile. Rows lacking the field (legacy / pre-R1)
  # count as eligible — only an explicit eligible:0 is excluded.
  local _vals
  _vals=$(cat "${_file}.1" "$_file" 2>/dev/null \
    | jq -R 'fromjson?' \
    | jq -s --arg f "$_field" --argjson cutoff "$_cutoff" '
        map(select((.ts | fromdateiso8601? // 0) >= $cutoff))
        | map(select((.eligible // 1) != 0))
        | map(.[$f] // 0 | tonumber?)
        | map(select(. != null))
        | .[]
      ' 2>/dev/null)
  [ -z "$_vals" ] && { printf '0'; return 0; }
  printf '%s\n' "$_vals" | LC_ALL=C sort -g | _pp_awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) { printf "0"; exit }
      idx = int(0.95 * NR + 0.9999999)
      if (idx < 1) idx = 1
      if (idx > NR) idx = NR
      printf "%.6f", v[idx]
    }'
}

# === v0.5.2 Wilson 95% CI lower bound =========================================
# pp_kpi_wilson_lower_95 SUCCESSES TRIALS
# Stdout: 4-decimal float in [0, 1] — the Wilson score interval's lower
# bound at 95% confidence (z = 1.959963984540054, TWO-SIDED). Pure awk;
# bash-3.2-portable. Used by `polymath history` to display per-lens acted%
# confidence floors.
#
# Formula (Wilson score interval, lower bound):
#   center = (p + z²/(2n)) / (1 + z²/n)
#   margin = (z * sqrt(p(1-p)/n + z²/(4n²))) / (1 + z²/n)
#   lower  = max(0, center - margin)
# where p = SUCCESSES / TRIALS, n = TRIALS, z = 1.959963984540054 (95% two-sided).
#
# TWO-SIDED vs ONE-SIDED z (Task 10 review note): spec §D's example shows
# 2/7 → 0.064, which is the ONE-SIDED z=1.645 value. This implementation uses
# the TWO-SIDED z=1.96 per the plan (yields 2/7 → 0.0822). One-sided would
# be a less conservative floor; two-sided is the right "I'm 95% sure the
# true rate is at least this" interpretation for downstream gating.
#
# Edge case: TRIALS=0 → return 0.0000 (no data, no claim). Non-numeric inputs
# are coerced to 0 (defensive). Output is locale-independent (LC_ALL=C).
#
# GPT-review #1 + #3 — s > n guard:  if successes > trials, p(1-p) goes
# negative and sqrt() emits NaN, corrupting downstream consumers. Clamp s
# to [0, n] and let p = 1 in the impossible-data case. (Could also reject
# with rc=1, but the plan contract says "always return a float on stdout";
# clamping preserves that contract and surfaces the upper bound as the
# pessimistic floor — i.e. "if you claim k > n, we'll show you a 100%
# success rate's lower bound").
pp_kpi_wilson_lower_95() {
  local _s="${1:-0}" _n="${2:-0}"
  case "$_s" in ''|*[!0-9]*) _s=0 ;; esac
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  [ "$_n" -eq 0 ] && { printf '0.0000'; return 0; }
  # Clamp s to [0, n] to prevent sqrt(negative) → NaN when caller data
  # has k > n (corrupt counter, double-counted retries, etc.).
  if [ "$_s" -gt "$_n" ]; then
    _s="$_n"
  fi
  LC_ALL=C awk -v s="$_s" -v n="$_n" '
    BEGIN {
      z = 1.959963984540054
      z2 = z * z
      p = s / n
      center = (p + z2 / (2 * n)) / (1 + z2 / n)
      margin = (z * sqrt(p * (1 - p) / n + z2 / (4 * n * n))) / (1 + z2 / n)
      lower = center - margin
      if (lower < 0) lower = 0
      printf "%.4f", lower
    }'
}
