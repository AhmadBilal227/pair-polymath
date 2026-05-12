#!/usr/bin/env bash
# Pair Polymath — LRU-by-activation eviction with eviction-summary preservation.
#
# Contract:
#   pp_memory_evict CWD
#     1. Check observations.sqlite file size.
#     2. If under $PP_MEMORY_MAX_BYTES (default 100MB): noop, return 0.
#     3. Select bottom-K rows by activation_score (K = $PP_MEMORY_EVICT_BATCH_SIZE,
#        default 50).
#     4. Summarize the cohort into ONE pattern entry via the eviction-summary
#        LLM prompt (mockable via PP_MEMORY_LLM_BIN).
#     5. Append summary to patterns.jsonl with type="eviction_summary".
#     6. DELETE the K rows in one transaction.
#     7. Run wal_checkpoint(TRUNCATE) to actually release disk space.
#
# Failure mode:
#   - LLM unavailable or returns no valid summary → ABORT. Do NOT delete
#     observations without a preserved summary; rerun later when the LLM
#     is reachable.
#
# Locking: the whole flow runs under pp_memory_with_lock so concurrent
# inserts/recomputes block during the multi-statement RMW.

if [ -z "${PP_ROOT:-}" ]; then
  _pp_memory_evict_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
  PP_ROOT="$_pp_memory_evict_dir"
  unset _pp_memory_evict_dir
fi
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/schema.sh"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/lock.sh"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/patterns.sh"

# _pp_memory_evict_is_number VAL
_pp_memory_evict_is_number() {
  local val="$1"
  case "$val" in
    ''|*[!0-9.-]*) return 1 ;;
  esac
  printf '%s' "$val" | LC_ALL=C grep -qE '^-?[0-9]+(\.[0-9]+)?$'
}

# _pp_memory_db_size PATH
# Stdout: file size in bytes (BSD/GNU stat fallback).
_pp_memory_db_size() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return 0; }
  stat -f %z "$f" 2>/dev/null \
    || stat -c %s "$f" 2>/dev/null \
    || printf '0'
}

# _pp_memory_summarize_for_eviction PROJ_DIR ROWS_JSON COUNT
# Invoke the eviction-summary LLM. On success, appends ONE line to
# patterns.jsonl tagged type=eviction_summary. Returns 0 if a valid summary
# was persisted; 1 if no summary was produced (caller MUST abort).
_pp_memory_summarize_for_eviction() {
  local proj_dir="$1" rows="$2" count="$3"
  local sys
  sys=$(_pp_memory_load_prompt eviction-summary) || return 1
  [ -z "$sys" ] && return 1

  local user_input
  user_input=$(jq -nc --argjson rows "$rows" --argjson count "$count" \
    '{evicted_count:$count, rows:$rows}')

  local response llm_rc=0
  response=$(_pp_memory_invoke_llm "$sys" "$user_input") || llm_rc=$?
  [ "$llm_rc" -ne 0 ] && return 1
  [ -z "$response" ] && return 1

  # Strip accidental code fences. Parse expecting a single JSON object.
  local cleaned
  cleaned=$(printf '%s' "$response" | LC_ALL=C sed -E 's/^```(json)?$//; s/^```$//')

  # Validate required fields. Empty/malformed → 1 (caller aborts).
  local title evidence lens_ids conf type evicted
  title=$(printf '%s' "$cleaned" | jq -r '.title // ""' 2>/dev/null || true)
  [ -z "$title" ] && return 1
  evidence=$(printf '%s' "$cleaned" | jq -c '.evidence_obs_ids // []' 2>/dev/null || true)
  [ -z "$evidence" ] && evidence='[]'
  lens_ids=$(printf '%s' "$cleaned" | jq -c '.lens_ids // []' 2>/dev/null || true)
  [ -z "$lens_ids" ] && lens_ids='[]'
  conf=$(printf '%s' "$cleaned" | jq -r '.confidence // 0.5' 2>/dev/null || true)
  _pp_memory_evict_is_number "$conf" || conf=0.5
  type=$(printf '%s' "$cleaned" | jq -r '.type // "eviction_summary"' 2>/dev/null || true)
  evicted=$(printf '%s' "$cleaned" | jq -r '.evicted_count // 0' 2>/dev/null || true)
  _pp_memory_evict_is_number "$evicted" || evicted="$count"

  local now pid line
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  pid=$(_pp_memory_pattern_id "$title" "$now")
  line=$(jq -nc \
    --arg id "$pid" \
    --arg ts "$now" \
    --arg title "$title" \
    --argjson evidence "$evidence" \
    --argjson lens_ids "$lens_ids" \
    --argjson confidence "$conf" \
    --arg type "$type" \
    --argjson evicted_count "$evicted" \
    '{id:$id, extracted_at:$ts, title:$title,
      evidence_obs_ids:$evidence, lens_ids:$lens_ids,
      confidence:$confidence, type:$type, evicted_count:$evicted_count}')
  local jsonl="$proj_dir/patterns.jsonl"
  printf '%s\n' "$line" >> "$jsonl"
  chmod 600 "$jsonl" 2>/dev/null || true

  local max_keep="${PP_MEMORY_PATTERNS_MAX:-1000}"
  _pp_memory_rotate_patterns_jsonl "$jsonl" "$max_keep" || true
  return 0
}

# _pp_memory_evict_inner CWD
# The protected body of pp_memory_evict — called with the maintenance lock
# held (function-name signature, no eval).
_pp_memory_evict_inner() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0

  local max_bytes="${PP_MEMORY_MAX_BYTES:-104857600}"
  if ! _pp_memory_evict_is_number "$max_bytes"; then
    printf 'pp_memory_evict: invalid PP_MEMORY_MAX_BYTES=%s\n' "$max_bytes" >&2
    return 1
  fi

  local batch="${PP_MEMORY_EVICT_BATCH_SIZE:-50}"
  if ! _pp_memory_evict_is_number "$batch"; then
    printf 'pp_memory_evict: invalid PP_MEMORY_EVICT_BATCH_SIZE=%s\n' "$batch" >&2
    return 1
  fi

  local size
  size=$(_pp_memory_db_size "$db")
  _pp_memory_evict_is_number "$size" || return 0
  if [ "$size" -le "$max_bytes" ]; then
    return 0
  fi

  # Pull the bottom-K rows by activation_score (lowest first). LIMIT $batch.
  local rows_json
  rows_json=$(pp_memory_sqlite -json "$db" "
    SELECT obs_id, lens_id, topic, hook, body, ts
      FROM observations
     ORDER BY (activation_score IS NULL), activation_score ASC, obs_id ASC
     LIMIT $batch;
  " 2>/dev/null || true)
  [ -z "$rows_json" ] && return 0
  local rlen=""
  rlen=$(printf '%s' "$rows_json" | jq 'length' 2>/dev/null || true)
  _pp_memory_evict_is_number "$rlen" || return 0
  [ "$rlen" -eq 0 ] && return 0

  # Summarize-or-abort. If the LLM can't preserve the cohort gist, we MUST
  # leave the rows in place — better to grow past cap than lose memory.
  if ! _pp_memory_summarize_for_eviction "$proj_dir" "$rows_json" "$rlen"; then
    printf 'pp_memory_evict: summary failed; aborting eviction (rows preserved)\n' >&2
    return 1
  fi

  # Build the obs_id list and DELETE in one transaction.
  local ids_json
  ids_json=$(printf '%s' "$rows_json" | jq -c '[.[].obs_id]')
  local payload_tmp
  payload_tmp=$(mktemp "${TMPDIR:-/tmp}/pp-evict.ids.XXXXXX") || return 1
  chmod 600 "$payload_tmp" 2>/dev/null || true
  printf '%s\n' "$ids_json" > "$payload_tmp"

  pp_memory_sqlite "$db" <<SQL
BEGIN;
CREATE TEMP TABLE _eid(j TEXT);
.mode list
.import "$payload_tmp" _eid
DELETE FROM observations
 WHERE obs_id IN (SELECT value FROM _eid, json_each(_eid.j));
COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
SQL
  rm -f "$payload_tmp"
  return 0
}

# pp_memory_evict CWD
# Public entry point. Acquires the maintenance lock and delegates.
pp_memory_evict() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  pp_memory_db_init "$proj_dir"
  pp_memory_with_lock "$proj_dir" _pp_memory_evict_inner "$cwd"
}
