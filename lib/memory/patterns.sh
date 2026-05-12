#!/usr/bin/env bash
# Pair Polymath — emergent pattern extraction.
#
# Periodically clusters the last N observations and asks an LLM to extract
# recurring themes. Stores patterns as JSONL — append-only, capped by line
# count, rotated by deletion-from-front when capacity is exceeded.
#
# Contract:
#   pp_memory_extract_patterns CWD
#     Reads the last $PP_MEMORY_PATTERN_BATCH_SIZE observations (default
#     200), builds the extraction prompt, invokes the LLM (mockable via
#     PP_MEMORY_LLM_BIN env override), parses strict JSON output, appends
#     to $proj_dir/patterns.jsonl, then rotates if the JSONL exceeds
#     $PP_MEMORY_PATTERNS_MAX (default 1000).
#
#   pp_memory_top_patterns CWD K
#     Returns last K patterns from patterns.jsonl in reverse chronological
#     order (most recent first).
#
# LLM invocation:
#   PP_MEMORY_LLM_BIN if set → exec that binary, feed prompt+observations
#     on stdin, read JSON on stdout. Tests use a fixture shell script.
#   Otherwise, fall back to `llm -m gpt-5-mini -s <prompt>` if `llm` is
#     on PATH. If neither is available, return 0 silently (no JSONL write).
#
# Defense-in-depth:
#   - Empty obs set → noop, no JSONL write.
#   - LLM returns empty/malformed/non-JSON → log to stderr, no JSONL write.
#   - LLM returns {patterns:[]} → respected, no JSONL write.
#   - JSONL writes are atomic (tmp+append, fsync via printf).
#   - Cap enforcement done after each write to prevent unbounded growth.

if [ -z "${PP_ROOT:-}" ]; then
  _pp_memory_patterns_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
  PP_ROOT="$_pp_memory_patterns_dir"
  unset _pp_memory_patterns_dir
fi
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/schema.sh"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/redact.sh"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/lock.sh"

# _pp_memory_patterns_is_number VAL
# Numeric guard (matches the shape used in store.sh / activation.sh).
_pp_memory_patterns_is_number() {
  local val="$1"
  case "$val" in
    ''|*[!0-9.-]*) return 1 ;;
  esac
  printf '%s' "$val" | LC_ALL=C grep -qE '^-?[0-9]+(\.[0-9]+)?$'
}

# _pp_memory_load_prompt NAME
# Stdout: rendered template content. Honors user override under
# $HOME/.claude/pair-polymath/prompts/, then built-in $PP_ROOT/prompts/.
# Returns 1 (empty stdout) if neither exists.
_pp_memory_load_prompt() {
  local name="$1"
  local user_path="${HOME}/.claude/pair-polymath/prompts/${name}.md"
  local builtin_path="${PP_ROOT}/prompts/${name}.md"
  if [ -f "$user_path" ]; then
    cat "$user_path"
  elif [ -f "$builtin_path" ]; then
    cat "$builtin_path"
  else
    return 1
  fi
}

# _pp_memory_invoke_llm SYSTEM_PROMPT USER_INPUT
# Stdout: raw LLM response. Honors PP_MEMORY_LLM_BIN (test/CI fixture path)
# first; if absent, falls back to the `llm` CLI used elsewhere.
# Returns 1 if no LLM is available OR the invocation fails.
_pp_memory_invoke_llm() {
  local sys="$1" user="$2"
  local timeout_s="${PP_MEMORY_LLM_TIMEOUT_S:-60}"
  if [ -n "${PP_MEMORY_LLM_BIN:-}" ] && [ -x "${PP_MEMORY_LLM_BIN}" ]; then
    # Fixture/test path: pass system prompt as $1 and user input on stdin.
    # The fixture decides shape; we just hand it through.
    printf '%s' "$user" | "$PP_MEMORY_LLM_BIN" "$sys"
    return $?
  fi
  if command -v llm >/dev/null 2>&1; then
    local model="${PP_MEMORY_LLM_MODEL:-gpt-5-mini}"
    if command -v timeout >/dev/null 2>&1; then
      printf '%s' "$user" | timeout "$timeout_s" llm -m "$model" -s "$sys" 2>/dev/null
    elif command -v gtimeout >/dev/null 2>&1; then
      printf '%s' "$user" | gtimeout "$timeout_s" llm -m "$model" -s "$sys" 2>/dev/null
    else
      printf '%s' "$user" | llm -m "$model" -s "$sys" 2>/dev/null
    fi
    return $?
  fi
  return 1
}

# _pp_memory_pattern_id TITLE TS
# Stdout: pattern id "p-<12hex>" derived from sha1(title || ts). Deterministic
# given inputs; not security-critical (the JSONL is the source of truth).
_pp_memory_pattern_id() {
  local title="$1" ts="$2"
  printf 'p-%s' "$(printf '%s|%s' "$title" "$ts" \
    | { shasum 2>/dev/null || sha1sum 2>/dev/null; } \
    | LC_ALL=C cut -c1-12)"
}

# _pp_memory_rotate_patterns_jsonl PATH MAX
# If PATH has more than MAX lines, keep only the last MAX. Atomic via
# tmp+mv inside the same directory.
_pp_memory_rotate_patterns_jsonl() {
  local path="$1" max="$2"
  [ -f "$path" ] || return 0
  local lines
  lines=$(LC_ALL=C wc -l < "$path" 2>/dev/null | tr -d ' ')
  _pp_memory_patterns_is_number "$lines" || return 0
  if [ "$lines" -le "$max" ]; then
    return 0
  fi
  local dir tmp
  dir=$(dirname "$path")
  tmp=$(mktemp "${dir}/.patterns.rot.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  # Keep last $max lines.
  tail -n "$max" "$path" > "$tmp" 2>/dev/null
  mv "$tmp" "$path"
  chmod 600 "$path" 2>/dev/null || true
}

# _pp_memory_filter_valid_evidence INPUT_ROWS_JSON EVIDENCE_JSON
# R3.4 — defangs LLM-supplied evidence_obs_ids by intersecting against the
# set of obs_ids that were actually passed as input. The LLM can hallucinate
# or be primed (via crafted body content) into emitting attacker-controlled
# tokens; those would otherwise land in patterns.jsonl PERMANENTLY and
# re-surface in every future analyst prompt via pp_memory_top_patterns.
#
# Inputs:
#   $1 INPUT_ROWS_JSON   JSON array of {obs_id, ...} — the input the LLM saw
#   $2 EVIDENCE_JSON     JSON array of strings — the LLM's claimed evidence
# Output (stdout):       JSON array of strings — evidence ∩ input.obs_ids
_pp_memory_filter_valid_evidence() {
  local input_rows="$1" evidence="$2"
  # Both inputs may be missing / empty; emit '[]' as a safe default.
  [ -z "$input_rows" ] && { printf '[]'; return 0; }
  [ -z "$evidence" ] && { printf '[]'; return 0; }
  # Build the valid set from INPUT_ROWS_JSON. If parse fails, treat as empty.
  local valid_set
  valid_set=$(printf '%s' "$input_rows" \
    | jq -c '[.[] | .obs_id // empty] | unique' 2>/dev/null) || valid_set='[]'
  [ -z "$valid_set" ] && valid_set='[]'
  # Intersect. `IN($valid_set[])` in jq is the standard membership filter.
  # If EVIDENCE isn't a parseable JSON array, treat as empty.
  printf '%s' "$evidence" \
    | jq -c --argjson valid "$valid_set" \
        '[.[] | select(. as $x | $valid | index($x))]' 2>/dev/null \
    || printf '[]'
}

# _pp_memory_strip_code_fence
# Read stdin, strip a leading ```(json)? fence line and a trailing ``` fence
# line if present. More robust than the sed pattern it replaces — that one
# (`sed -E 's/^```$//'`) requires the fence to be the ONLY content on its
# line; a trailing `\n` or whitespace would slip through. (F11.)
_pp_memory_strip_code_fence() {
  LC_ALL=C awk '
    NR==1 && /^[[:space:]]*```([Jj][Ss][Oo][Nn])?[[:space:]]*$/ { next }
    { buf[++n] = $0 }
    END {
      end = n
      if (n > 0 && buf[n] ~ /^[[:space:]]*```[[:space:]]*$/) end = n - 1
      for (i = 1; i <= end; i++) print buf[i]
    }
  '
}

# _pp_memory_extract_patterns_inner CWD
# Body of pp_memory_extract_patterns. Runs under pp_memory_with_lock so the
# patterns.jsonl append/rotate is serialized against eviction's own append
# (F8 — concurrent invocations would otherwise interleave lines).
_pp_memory_extract_patterns_inner() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0

  local batch="${PP_MEMORY_PATTERN_BATCH_SIZE:-200}"
  if ! _pp_memory_patterns_is_number "$batch"; then
    printf 'pp_memory_extract_patterns: invalid batch size %s\n' "$batch" >&2
    return 1
  fi

  local max_keep="${PP_MEMORY_PATTERNS_MAX:-1000}"
  if ! _pp_memory_patterns_is_number "$max_keep"; then
    printf 'pp_memory_extract_patterns: invalid max %s\n' "$max_keep" >&2
    return 1
  fi

  # Pull recent obs as a JSON array. Skip empty DBs without further work.
  local count
  count=$(pp_memory_sqlite "$db" \
    "SELECT COUNT(*) FROM observations;" 2>/dev/null)
  _pp_memory_patterns_is_number "$count" || return 0
  [ "$count" -eq 0 ] && return 0

  # SQLite emits one JSON row per record with -json; wrap into a single array.
  # ORDER BY ts DESC pulls the most recent batch.
  local rows_json
  rows_json=$(pp_memory_sqlite -json "$db" "
    SELECT obs_id, lens_id, topic, hook, body, ts
      FROM observations
     ORDER BY ts DESC
     LIMIT $batch;
  " 2>/dev/null)
  # Empty result (only NULL string) → noop.
  [ -z "$rows_json" ] && return 0
  # Defensive: ensure it parses as a non-empty JSON array.
  local arr_len
  arr_len=$(printf '%s' "$rows_json" | jq 'length' 2>/dev/null)
  _pp_memory_patterns_is_number "$arr_len" || return 0
  [ "$arr_len" -eq 0 ] && return 0

  # Defense-in-depth (F4): re-redact each body at extraction-input time so a
  # secret stored before a redaction-pattern upgrade still gets stripped
  # before reaching the LLM. Hook and topic are usually short/structured;
  # body is the high-leverage field. This is intentionally a second pass —
  # the at-store-time redaction already ran when PP_MEMORY_REDACT=1.
  #
  # R3.17 — O(n) rewrite. The previous loop spawned 2 jq processes per row
  # AND rebuilt the accumulator JSON each iteration (O(n²) memory). For
  # batch=200 that was ~400 jq invocations + quadratic copy. This version
  # uses 2 jq invocations total: one to emit base64-encoded bodies (handles
  # multi-line bodies safely without separator-collision risk), then a
  # tight shell loop that redacts each, then one final jq to splice the
  # redacted bodies back into the rows array.
  if [ "${PP_MEMORY_REDACT:-1}" = "1" ]; then
    local _pp_bodies_b64 _pp_new_b64
    _pp_bodies_b64=$(printf '%s' "$rows_json" \
      | jq -r '.[].body // "" | @base64' 2>/dev/null)
    _pp_new_b64=""
    local _pp_enc _pp_body _pp_red _pp_red_enc
    while IFS= read -r _pp_enc; do
      if [ -z "$_pp_enc" ]; then
        # Empty body row — preserve as empty so the index alignment in the
        # zip step still matches.
        _pp_new_b64="${_pp_new_b64}"$'\n'
        continue
      fi
      _pp_body=$(printf '%s' "$_pp_enc" | base64 -d 2>/dev/null)
      _pp_red=$(pp_memory_redact_body "$_pp_body")
      _pp_red_enc=$(printf '%s' "$_pp_red" | base64 | LC_ALL=C tr -d '\n')
      _pp_new_b64="${_pp_new_b64}${_pp_red_enc}"$'\n'
    done <<EOF
$_pp_bodies_b64
EOF
    # Splice redacted bodies back into rows via a single jq call. We DROP
    # only the trailing empty element from split (which comes from the
    # final newline we always append in the loop). Empty-string entries
    # mid-array represent legitimately empty bodies and MUST be preserved
    # to keep the index alignment with $orig.
    rows_json=$(printf '%s' "$_pp_new_b64" \
      | jq -Rsc --argjson orig "$rows_json" '
          (split("\n") | if (length > 0 and .[-1] == "") then .[:-1] else . end) as $b64s
          | $orig
          | [range(length) as $i | .[$i] + {body: ($b64s[$i] // "" | @base64d)}]
        ' 2>/dev/null)
  fi

  # Load extraction prompt. Absence is non-fatal — without a prompt we can't
  # call the LLM, so we silently noop (matches the no-llm path).
  local sys_prompt
  sys_prompt=$(_pp_memory_load_prompt pattern-extraction) || return 0
  [ -z "$sys_prompt" ] && return 0

  # Invoke LLM. Capture rc separately so we can distinguish "no LLM" from
  # "LLM ran, returned bad output".
  local response llm_rc=0
  response=$(_pp_memory_invoke_llm "$sys_prompt" "$rows_json") || llm_rc=$?
  if [ "$llm_rc" -ne 0 ]; then
    # No LLM available (or invocation failed). Silent noop.
    return 0
  fi
  [ -z "$response" ] && return 0

  # Parse the response. Strip any accidental code fence the model added.
  # F11: awk-based stripper tolerates trailing whitespace + mixed-case `json`.
  local cleaned
  cleaned=$(printf '%s' "$response" | _pp_memory_strip_code_fence)
  # Verify it's a JSON object with a patterns array. `|| true` so callers
  # under `set -e` don't propagate jq's parse-error rc (5) out of the
  # function — we want to handle it as "no patterns" below.
  local patterns_arr=""
  patterns_arr=$(printf '%s' "$cleaned" \
    | jq -c '.patterns // [] | select(type=="array")' 2>/dev/null || true)
  if [ -z "$patterns_arr" ]; then
    printf 'pp_memory_extract_patterns: malformed JSON from LLM; skipping write\n' >&2
    return 0
  fi
  local plen=""
  plen=$(printf '%s' "$patterns_arr" | jq 'length' 2>/dev/null || true)
  _pp_memory_patterns_is_number "$plen" || return 0
  [ "$plen" -eq 0 ] && return 0

  # Append each pattern as one JSONL line. We materialize via jq so titles
  # with embedded newlines / quotes can't corrupt the file format.
  local jsonl="$proj_dir/patterns.jsonl"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Write to tmp then concatenate; this prevents a partial write on disk-full.
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/pp-patterns.append.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  local i title evidence lens_ids confidence pid line
  for i in $(seq 0 $((plen - 1))); do
    title=$(printf '%s' "$patterns_arr" | jq -r ".[$i].title // \"\"")
    [ -z "$title" ] && continue
    # R3.3 — sanitize title (length cap, control-char strip, role-override
    # rejection, secret redaction). On rejection, skip THIS pattern but keep
    # processing siblings — pattern-extraction emits a batch, so one bad
    # title shouldn't sink the whole cycle.
    title=$(pp_memory_sanitize_title "$title") || continue
    [ -z "$title" ] && continue
    evidence=$(printf '%s' "$patterns_arr" | jq -c ".[$i].evidence_obs_ids // []")
    # R3.4 — only retain evidence_obs_ids that were actually in the input
    # batch we sent to the LLM. The LLM (or a primed-via-injection LLM) can
    # otherwise stash attacker-controlled strings here.
    evidence=$(_pp_memory_filter_valid_evidence "$rows_json" "$evidence")
    lens_ids=$(printf '%s' "$patterns_arr" | jq -c ".[$i].lens_ids // []")
    confidence=$(printf '%s' "$patterns_arr" | jq -r ".[$i].confidence // 0.5")
    _pp_memory_patterns_is_number "$confidence" || confidence=0.5
    pid=$(_pp_memory_pattern_id "$title" "$now")
    line=$(jq -nc \
      --arg id "$pid" \
      --arg ts "$now" \
      --arg title "$title" \
      --argjson evidence "$evidence" \
      --argjson lens_ids "$lens_ids" \
      --argjson confidence "$confidence" \
      '{id:$id, extracted_at:$ts, title:$title,
        evidence_obs_ids:$evidence, lens_ids:$lens_ids,
        confidence:$confidence}')
    printf '%s\n' "$line" >> "$tmp"
  done

  # If nothing valid survived the per-pattern filter, exit clean.
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    return 0
  fi

  # Append-to-jsonl is the canonical atomic op for line-oriented logs:
  # >> open + write is one syscall on POSIX up to PIPE_BUF (~4KB), and our
  # lines are <1KB. We don't need a temp+mv here.
  mkdir -p "$proj_dir" 2>/dev/null || true
  chmod 700 "$proj_dir" 2>/dev/null || true
  cat "$tmp" >> "$jsonl"
  chmod 600 "$jsonl" 2>/dev/null || true
  rm -f "$tmp"

  # Rotate if we exceeded the cap.
  _pp_memory_rotate_patterns_jsonl "$jsonl" "$max_keep" || true
  return 0
}

# pp_memory_extract_patterns CWD
# Public entry. Acquires the maintenance lock and delegates so the JSONL
# append + rotate cannot interleave with eviction's own JSONL append (F8).
pp_memory_extract_patterns() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  # Be tolerant of callers that didn't init the DB first (lazy init).
  pp_memory_db_init "$proj_dir" 2>/dev/null || true
  pp_memory_with_lock "$proj_dir" _pp_memory_extract_patterns_inner "$cwd"
}

# pp_memory_top_patterns CWD K
# Stdout: JSON array of top-K patterns from JSONL, re-ranked by
#   score = confidence * exp(-0.05 * days_since(extracted_at))
# F12: pure recency-order surfaced low-confidence eviction summaries and
# suspected-injection placeholders ahead of solid high-conf patterns. The
# rerank keeps recency a factor (k=0.05/day → half-life ~14d) but lets
# confidence dominate when both are recent. No tac — BSD-missing — so we
# reverse via awk + sort via jq.
pp_memory_top_patterns() {
  local cwd="$1" k="${2:-10}"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || { printf '[]'; return 0; }
  local jsonl="$proj_dir/patterns.jsonl"
  if [ ! -f "$jsonl" ] || [ ! -s "$jsonl" ]; then
    printf '[]'
    return 0
  fi
  if ! _pp_memory_patterns_is_number "$k"; then
    printf '[]'
    return 1
  fi
  # Read entire file → jq slurp into array → compute score → sort desc → take K.
  # Score: confidence * 1/(1 + 0.05 * days). 1/(1+kt) is bounded in (0,1],
  # monotonically decreasing, and never collapses to 0 — so identical
  # confidences still sort by recency (more-recent ⇒ smaller denominator
  # ⇒ larger score). jq pre-1.6 lacks exp(); 1/(1+kt) needs only +,*,/.
  # _age is also kept as a stable tiebreaker (smaller age first) for
  # numerically-identical scores (e.g. multi-decimal precision quirks).
  local out
  out=$(LC_ALL=C awk 'NF' "$jsonl" 2>/dev/null \
    | jq -cs '
        map(. + {
          _age:   ((now - ((.extracted_at // "1970-01-01T00:00:00Z") | fromdateiso8601)) / 86400),
          _score: ((.confidence // 0)
                   / (1 + 0.05 * ((now - ((.extracted_at // "1970-01-01T00:00:00Z")
                                           | fromdateiso8601)) / 86400)))
        })
        | sort_by([-(._score), ._age])
        | map(del(._score, ._age))
        | .[:'"$k"']
      ' 2>/dev/null || true)
  if [ -z "$out" ]; then
    printf '[]'
  else
    printf '%s' "$out"
  fi
}
