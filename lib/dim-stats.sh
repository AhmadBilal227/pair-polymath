#!/usr/bin/env bash
# v0.5.3 — Developer Insights Module statistical helpers.
#
# Pure-math primitives consumed by lib/dim.sh. No I/O, no env reads beyond
# the salt path. Bash 3.2-portable: no mapfile, no ${var,,}, no local -n.
# LC_ALL=C enforced at file top to neutralize locale-dependent awk printf
# behavior on the Wilson / anytime-CS calculations.

[ "${_PP_DIM_STATS_SOURCED:-0}" = "1" ] && return 0

export LC_ALL=C
_PP_DIM_STATS_SOURCED=1

# pp_dim_stats_lcb_anytime SUCCESSES TRIALS ALPHA
# Time-uniform Wilson-style lower confidence bound (Howard et al. 2021).
# Holds simultaneously for all n; safe to peek at arbitrary times.
# Echoes the bound as a float (locale-independent).
pp_dim_stats_lcb_anytime() {
  local s="${1:-0}" n="${2:-0}" alpha="${3:-0.05}"
  LC_ALL=C awk -v s="$s" -v n="$n" -v alpha="$alpha" 'BEGIN {
    if (n + 0 <= 0) { printf "0.0000\n"; exit }
    # Alpha must be in (0, 1) — otherwise the log(2/alpha) term is
    # undefined (alpha<=0) or non-positive (alpha>=2), which silently
    # produces an over-confident LCB. Refuse with a conservative 0.
    if (alpha + 0 <= 0 || alpha + 0 >= 1) { printf "0.0000\n"; exit }
    if (s + 0 < 0)  s = 0
    if (s + 0 > n)  s = n
    n2 = (2.0 * n < 4 ? 4 : 2.0 * n)
    psi2 = log(log(n2)) + log(2.0 / alpha)
    if (psi2 < 0) psi2 = 0
    psi = sqrt(psi2)
    denom = n + psi2
    center = (s + 0.5 * psi2) / denom
    inner = s * (n - s) / n + 0.25 * psi2
    if (inner < 0) inner = 0
    margin = psi * sqrt(inner) / denom
    lcb = center - margin
    if (lcb < 0) lcb = 0
    printf "%.4f\n", lcb
  }'
}

# pp_dim_stats_events_to_clear S N ALPHA TARGET_LCB
# Returns the smallest integer DELTA_N such that
#   pp_dim_stats_lcb_anytime(S + round(p_hat * DELTA_N), N + DELTA_N, ALPHA) >= TARGET_LCB
# where p_hat = S / N. Returns 0 if already cleared.
# Returns -1 if mathematically impossible (p_hat <= TARGET_LCB).
# Search is exponential-then-bisect for O(log n) calls.
pp_dim_stats_events_to_clear() {
  local s="${1:-0}" n="${2:-0}" alpha="${3:-0.05}" target="${4:-0.05}"
  local cur
  cur=$(pp_dim_stats_lcb_anytime "$s" "$n" "$alpha")
  if LC_ALL=C awk -v c="$cur" -v t="$target" 'BEGIN { exit (c >= t) ? 0 : 1 }'; then
    echo "0"
    return 0
  fi
  if LC_ALL=C awk -v s="$s" -v n="$n" -v t="$target" 'BEGIN {
        if (n <= 0) { exit 1 }
        exit (s / n <= t) ? 0 : 1
      }'; then
    echo "-1"
    return 0
  fi
  local delta=1 max_probe=1000000
  local probe_s probe_n probe_lcb
  while [ "$delta" -lt "$max_probe" ]; do
    probe_n=$((n + delta))
    probe_s=$(LC_ALL=C awk -v s="$s" -v n="$n" -v d="$delta" 'BEGIN {
      printf "%d", s + int((s * d) / n + 0.5)
    }')
    probe_lcb=$(pp_dim_stats_lcb_anytime "$probe_s" "$probe_n" "$alpha")
    if LC_ALL=C awk -v c="$probe_lcb" -v t="$target" 'BEGIN { exit (c >= t) ? 0 : 1 }'; then
      break
    fi
    delta=$((delta * 2))
  done
  [ "$delta" -ge "$max_probe" ] && { echo "$max_probe"; return 0; }
  # lo=0 is guaranteed non-clearing because the "already cleared" case
  # short-circuits earlier; this gives the bisect a proven lower bound
  # regardless of the exponential probe's first hit.
  local lo=0 hi="$delta" mid
  while [ "$((hi - lo))" -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    probe_n=$((n + mid))
    probe_s=$(LC_ALL=C awk -v s="$s" -v n="$n" -v d="$mid" 'BEGIN {
      printf "%d", s + int((s * d) / n + 0.5)
    }')
    probe_lcb=$(pp_dim_stats_lcb_anytime "$probe_s" "$probe_n" "$alpha")
    if LC_ALL=C awk -v c="$probe_lcb" -v t="$target" 'BEGIN { exit (c >= t) ? 0 : 1 }'; then
      hi="$mid"
    else
      lo="$mid"
    fi
  done
  echo "$hi"
}

# _pp_dim_stats_ensure_salt
# Idempotent: creates $PP_HOME/dim-holdout-salt with 16 random hex bytes
# (mode 0600) if absent. Returns 0 on success.
_pp_dim_stats_ensure_salt() {
  local home="${PP_HOME:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath}"
  local salt_file="$home/dim-holdout-salt"
  [ -s "$salt_file" ] && return 0
  mkdir -p "$home" 2>/dev/null || return 1
  chmod 700 "$home" 2>/dev/null || true
  # 16 bytes from /dev/urandom, hex-encoded → 32 chars.
  # od is portable; printf '%02x' loops are slow but more portable.
  local tmp
  tmp=$(mktemp "${salt_file}.XXXXXX") || return 1
  LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' > "$tmp"
  chmod 600 "$tmp" 2>/dev/null
  mv "$tmp" "$salt_file"
  return 0
}

# pp_dim_stats_holdout_slot SESSION_ID LENS INJECT_TS
# Echoes integer 0..9. Slot 0 means the row is in the holdout (10% sampled out).
# Salt is loaded lazily; hash is sha256 of salt||session_id||lens||inject_ts,
# taking the first 8 hex chars as a uint32 and reducing mod 10.
pp_dim_stats_holdout_slot() {
  local sid="${1:-}" lens="${2:-}" ts="${3:-}"
  _pp_dim_stats_ensure_salt || { echo "0"; return 1; }
  local home="${PP_HOME:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath}"
  local salt
  salt=$(cat "$home/dim-holdout-salt" 2>/dev/null) || { echo "0"; return 1; }
  local input="${salt}|${sid}|${lens}|${ts}"
  # Portable sha256 — Mac has shasum, Linux often has sha256sum.
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$input" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$input" | sha256sum | awk '{print $1}')
  else
    echo "0"
    return 1
  fi
  # Convert first 8 hex chars to int; mod 10. Use awk for big-int safety.
  LC_ALL=C awk -v hex="$digest" 'BEGIN {
    s = substr(hex, 1, 8)
    val = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      val *= 16
      if (c ~ /[0-9]/) val += c + 0
      else if (c == "a") val += 10
      else if (c == "b") val += 11
      else if (c == "c") val += 12
      else if (c == "d") val += 13
      else if (c == "e") val += 14
      else if (c == "f") val += 15
    }
    printf "%d\n", val % 10
  }'
}

# pp_dim_stats_composite_gate LENS_JSON ALPHA TARGET_LCB MIN_LENSES MIN_N MIN_DISTINCT_DATES
# LENS_JSON: JSON array of {lens, s, n, distinct_dates}
# Returns JSON: {qualifies, lenses_qualifying, per_lens: [{lens, s, n, lcb, qualifies, fail_reason?}]}
# Applies Bonferroni-across-lenses: each lens uses alpha/L where L = len(input).
pp_dim_stats_composite_gate() {
  local lens_json="$1" alpha="${2:-0.05}" target="${3:-0.05}"
  local min_lenses="${4:-3}" min_n="${5:-250}" min_dates="${6:-5}"
  local n_lenses
  n_lenses=$(printf '%s' "$lens_json" | jq -r 'length' 2>/dev/null)
  [ -z "$n_lenses" ] || [ "$n_lenses" -eq 0 ] && {
    printf '{"qualifies":false,"lenses_qualifying":0,"per_lens":[]}\n'
    return 0
  }
  local alpha_per
  alpha_per=$(LC_ALL=C awk -v a="$alpha" -v L="$n_lenses" 'BEGIN { printf "%.6f", a / L }')
  # Iterate per lens via jq → bash loop. Build per_lens array.
  local per_lens="[]"
  local i lens s n dates lcb qualifies fail_reason row
  for i in $(seq 0 $((n_lenses - 1))); do
    lens=$(printf '%s' "$lens_json" | jq -r ".[$i].lens")
    s=$(printf '%s' "$lens_json" | jq -r ".[$i].s // 0")
    n=$(printf '%s' "$lens_json" | jq -r ".[$i].n // 0")
    dates=$(printf '%s' "$lens_json" | jq -r ".[$i].distinct_dates // 0")
    lcb=$(pp_dim_stats_lcb_anytime "$s" "$n" "$alpha_per")
    qualifies="true"
    fail_reason=""
    if [ "$n" -lt "$min_n" ]; then
      qualifies="false"; fail_reason="n_below_floor"
    elif [ "$dates" -lt "$min_dates" ]; then
      qualifies="false"; fail_reason="distinct_dates_below_floor"
    elif ! LC_ALL=C awk -v l="$lcb" -v t="$target" 'BEGIN { exit (l >= t) ? 0 : 1 }'; then
      qualifies="false"; fail_reason="lcb_below_target"
    fi
    row=$(jq -nc --arg lens "$lens" --argjson s "$s" --argjson n "$n" \
                 --argjson dates "$dates" --arg lcb "$lcb" \
                 --argjson qualifies "$qualifies" --arg fail_reason "$fail_reason" \
      '{lens:$lens, s:$s, n:$n, distinct_dates:$dates, lcb:($lcb|tonumber), qualifies:$qualifies}
       + (if $fail_reason != "" then {fail_reason:$fail_reason} else {} end)')
    per_lens=$(printf '%s' "$per_lens" | jq -c ". + [$row]")
  done
  local n_qual
  n_qual=$(printf '%s' "$per_lens" | jq '[.[] | select(.qualifies == true)] | length')
  local qualifies
  if [ "$n_qual" -ge "$min_lenses" ]; then qualifies="true"; else qualifies="false"; fi
  jq -nc --argjson qualifies "$qualifies" --argjson n_qual "$n_qual" --argjson per_lens "$per_lens" \
    '{qualifies:$qualifies, lenses_qualifying:$n_qual, per_lens:$per_lens}'
}

# pp_dim_stats_per_lens_rollup OAR_FILE PROJECT_SHA8
# Reads OAR labeled JSONL, filters to project_root_sha8 == PROJECT_SHA8,
# splits into gated (holdout_slot != 0) and holdout (slot == 0),
# groups by lens, computes {lens, s, n, distinct_dates} for each bucket.
# Echoes JSON: {gated: [...], holdout: [...]}.
pp_dim_stats_per_lens_rollup() {
  local oar="$1" sha8="${2:-}"
  [ -f "$oar" ] || { printf '{"gated":[],"holdout":[]}\n'; return 0; }
  # Stamp holdout_slot per row in a temp jsonl, then group server-side via jq.
  local stamped
  stamped=$(mktemp) || return 1
  local sid lens ts slot
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    # Filter by project before doing the (expensive) hash
    if [ -n "$sha8" ]; then
      row_sha=$(printf '%s' "$row" | jq -r '.project_root_sha8 // ""')
      [ "$row_sha" = "$sha8" ] || continue
    fi
    sid=$(printf '%s' "$row" | jq -r '.session_id // ""')
    lens=$(printf '%s' "$row" | jq -r '.lens // ""')
    ts=$(printf '%s' "$row" | jq -r '.inject_ts // ""')
    slot=$(pp_dim_stats_holdout_slot "$sid" "$lens" "$ts")
    printf '%s\n' "$row" | jq -c --argjson slot "$slot" '. + {_dim_holdout_slot: $slot}' >> "$stamped"
  done < "$oar"
  # Group by bucket × lens via jq.
  local rollup
  rollup=$(jq -sc '
    def acted_filter: . | select(.outcome == "acted") | .;
    def date_of: (.inject_ts // "")[0:10];
    def group_lens(bucket):
      . | group_by(.lens)
        | map({
            lens: .[0].lens,
            s: ([.[] | select(.outcome == "acted")] | length),
            n: length,
            distinct_dates: ([.[] | date_of] | unique | length)
          });
    {
      gated:   ([.[] | select(._dim_holdout_slot != 0)] | group_lens("gated")),
      holdout: ([.[] | select(._dim_holdout_slot == 0)] | group_lens("holdout"))
    }
  ' "$stamped")
  rm -f "$stamped"
  printf '%s\n' "$rollup"
}
