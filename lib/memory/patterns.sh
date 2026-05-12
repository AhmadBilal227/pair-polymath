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

# pp_memory_extract_patterns CWD
# Cluster recent observations and append discovered patterns to JSONL.
pp_memory_extract_patterns() {
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
  local cleaned
  cleaned=$(printf '%s' "$response" | LC_ALL=C sed -E 's/^```(json)?$//; s/^```$//')
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
    evidence=$(printf '%s' "$patterns_arr" | jq -c ".[$i].evidence_obs_ids // []")
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

# pp_memory_top_patterns CWD K
# Stdout: JSON array of last K patterns from JSONL, most recent first.
# No tac — macOS BSD doesn't ship it. Reverse via awk array.
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
  # Last K lines, reversed (most recent first) via awk, wrapped in JSON array.
  local out
  out=$(tail -n "$k" "$jsonl" 2>/dev/null \
    | LC_ALL=C awk 'NF { a[++n]=$0 } END { for (i=n; i>=1; i--) print a[i] }' \
    | jq -cs '.' 2>/dev/null || true)
  if [ -z "$out" ]; then
    printf '[]'
  else
    printf '%s' "$out"
  fi
}
