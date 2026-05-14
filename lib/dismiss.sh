#!/usr/bin/env bash
# Pair Polymath — dismiss subsystem. v0.5 Phase 3.
# Storage: append-only JSONL at $PP_STATE_DIR/dismiss/<project_hash>.jsonl.
# Reuses lib/memory/schema.sh::pp_memory_project_hash for project identity.

umask 077

pp_dismiss_file_path() {
  if ! type pp_memory_project_hash >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${PP_ROOT:-.}/lib/memory/schema.sh" 2>/dev/null || return 1
  fi
  local _proj
  _proj=$(pp_memory_project_hash "${PWD}") || return 1
  local _dir="${PP_STATE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath}/dismiss"
  mkdir -p "$_dir" 2>/dev/null
  printf '%s/%s.jsonl' "$_dir" "$_proj"
}

pp_dismiss_add() {
  local _reason="${1:?pp_dismiss_add requires a reason summary}"
  local _scope="${2:-project}"
  local _lens="${3:-}"
  local _file _id _ts
  _file=$(pp_dismiss_file_path) || return 1
  _id="d-$(date +%Y-%m-%d)-$(printf '%04x' $(( RANDOM * RANDOM % 65535 )))"
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -nc \
    --arg id "$_id" --arg ts "$_ts" \
    --arg reason "$_reason" --arg scope "$_scope" --arg lens "$_lens" \
    '{
       id: $id, ts: $ts,
       reason_summary: $reason, scope: $scope,
       lens_id: (if $lens == "" then null else $lens end),
       hash: null, deleted: false, deleted_reason: null,
       ttl_days: null, source: "manual"
     }' >> "$_file"
  printf '%s' "$_id"
}

pp_dismiss_list() {
  local _scope_filter="${1:-}"
  local _file
  _file=$(pp_dismiss_file_path) || return 1
  if [ ! -f "$_file" ]; then
    printf 'No suppression rules yet. Add one: polymath dismiss "<reason>"\n'
    return 0
  fi
  local _now_s
  _now_s=$(date +%s)
  jq -s -r --arg scope "$_scope_filter" --arg now "$_now_s" '
    group_by(.id) | map(last)
    | .[]
    | select(.deleted == false)
    | select(.ttl_days == null or (
        (.ts | fromdateiso8601) + (.ttl_days * 86400) > ($now | tonumber)
      ))
    | select($scope == "" or .scope == $scope)
    | "\(.id)  \(.scope)  \(.reason_summary)"
  ' "$_file"
}

# pp_dismiss_show ID
# Prints the full JSON record (most-recent if id has multiple history entries).
pp_dismiss_show() {
  local _id="${1:?pp_dismiss_show requires an id}"
  local _file
  _file=$(pp_dismiss_file_path) || return 1
  [ ! -f "$_file" ] && return 1
  local _line
  _line=$(jq -c --arg id "$_id" 'select(.id == $id)' "$_file" 2>/dev/null | tail -1)
  if [ -z "$_line" ]; then
    printf 'pp_dismiss: id %s not found\n' "$_id" >&2
    return 1
  fi
  printf '%s\n' "$_line"
}

# pp_dismiss_disable ID [REASON=user_disabled]
# Appends a new JSONL line for the rule with deleted=true. Append-only;
# previous lines for the same id stay as audit history. pp_dismiss_show
# returns the latest, so this is effectively a state transition.
pp_dismiss_disable() {
  local _id="${1:?pp_dismiss_disable requires an id}"
  local _reason="${2:-user_disabled}"
  local _file
  _file=$(pp_dismiss_file_path) || return 1
  local _current
  _current=$(jq -c --arg id "$_id" 'select(.id == $id)' "$_file" 2>/dev/null | tail -1)
  [ -z "$_current" ] && { printf 'pp_dismiss: id %s not found\n' "$_id" >&2; return 1; }
  printf '%s\n' "$_current" \
    | jq -c --arg r "$_reason" '. + {deleted: true, deleted_reason: $r}' \
    >> "$_file"
}

# pp_dismiss_render
# Builds the project-constraints block for analyst prompt injection.
# Deterministic (no LLM): dedup by exact reason match, sort by source DESC
# then ts DESC, top 8 bullets, <=200 chars/bullet (truncate at word boundary),
# total cap PP_DISMISS_RENDERED_MAX_BYTES (default 2048).
#
# Cache invalidation (I4): content-hash header `# bytes=<n> hash=<sha1>`.
# We don't trust mtime — backup-restore + clock-skew can make stale caches
# look fresh by mtime alone. Hashing the source is strictly stronger.
#
# Output (I6): when rules exist, emit the FULL stanza (header + bullets +
# footer) so prompts/analyst-primary.md can use a bare ${project_constraints}
# placeholder without rendering "Constraints: ." when the list is empty.
pp_dismiss_render() {
  local _max="${PP_DISMISS_RENDERED_MAX_BYTES:-2048}"
  case "$_max" in ''|*[!0-9]*) _max=2048 ;; esac
  local _file _cache _proj
  _file=$(pp_dismiss_file_path) || return 1
  if ! type pp_memory_project_hash >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${PP_ROOT:-.}/lib/memory/schema.sh" 2>/dev/null || return 1
  fi
  _proj=$(pp_memory_project_hash "$PWD") || return 1
  _cache="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/cc-dismiss-rendered-${_proj}.txt"
  # I3 — no source rules: emit empty, only touch cache if needed to avoid
  # cache-mtime churn on every 2s statusline refresh on a fresh install.
  if [ ! -f "$_file" ]; then
    if [ ! -f "$_cache" ] || [ -s "$_cache" ]; then
      : > "$_cache"
    fi
    return 0
  fi
  # I4 — content-hash cache validation. Compute header for current source.
  local _src_bytes _src_hash _expected_hdr
  _src_bytes=$(LC_ALL=C wc -c < "$_file" 2>/dev/null | tr -d ' ')
  _src_hash=$(shasum < "$_file" 2>/dev/null | cut -d' ' -f1)
  _expected_hdr="# bytes=$_src_bytes hash=$_src_hash"
  if [ -f "$_cache" ]; then
    local _cache_hdr
    _cache_hdr=$(head -1 "$_cache" 2>/dev/null)
    if [ "$_cache_hdr" = "$_expected_hdr" ]; then
      tail -n +2 "$_cache"
      return 0
    fi
  fi
  # C1 — re-render with latest-wins fold per id. Without this, a disable
  # appends a deleted=true line but the original deleted=false line is still
  # in the JSONL and slips past select(.deleted == false).
  local _now_s _bullets
  _now_s=$(date +%s)
  _bullets=$(jq -s -r --arg now "$_now_s" '
    group_by(.id) | map(last)
    | .[]
    | select(.deleted == false)
    | select(.ttl_days == null or (
        (.ts | fromdateiso8601) + (.ttl_days * 86400) > ($now | tonumber)
      ))
    | "\(if .source == "manual" then "0" else "1" end)\t\(.ts)\t\(.reason_summary)"
  ' "$_file" \
    | sort -t "$(printf '\t')" -k1,1 -k2,2r \
    | awk -F'\t' '!seen[$3]++ {print "- " $3}' \
    | head -8)
  # Per-bullet truncate at 200 chars (word boundary).
  _bullets=$(printf '%s\n' "$_bullets" | awk '{
    if (length($0) > 200) {
      s = substr($0, 1, 200)
      sub(/ [^ ]*$/, "", s)
      print s
    } else { print }
  }')
  # Strip leading/trailing empty lines that the awk above can introduce
  # (e.g. when the input is empty, awk prints a single blank line).
  _bullets=$(printf '%s' "$_bullets" | LC_ALL=C sed -e '/./,$!d' -e ':a' -e '/^$/{$d;N;ba' -e '}')
  # I6 — empty bullets means no active rules. Emit nothing so the analyst
  # prompt doesn't carry a "Constraints: ." fragment.
  if [ -z "$_bullets" ]; then
    # Write cache with header only — header changes if source changes, so
    # this is still cache-valid for the current source.
    printf '%s\n' "$_expected_hdr" > "$_cache"
    return 0
  fi
  # I6 — wrap bullets in the full stanza. Caller's prompt template uses a
  # bare ${project_constraints}; this string is the entire block.
  local _stanza_hdr="Constraints from prior dismissals (do not flag these unless the diff materially changes the underlying state):"
  local _rendered="${_stanza_hdr}
${_bullets}"
  # Total-bytes cap on the full rendered stanza. If the header + first
  # bullet alone already exceeds _max, the stanza is dropped entirely
  # (better silent than truncated mid-bullet).
  local _byte_count
  _byte_count=$(printf '%s' "$_rendered" | LC_ALL=C wc -c | tr -d ' ')
  if [ "$_byte_count" -gt "$_max" ]; then
    local _acc _line _new_acc
    _acc="$_stanza_hdr"
    while IFS= read -r _line; do
      _new_acc="${_acc}
${_line}"
      if [ "$(printf '%s' "$_new_acc" | LC_ALL=C wc -c | tr -d ' ')" -le "$_max" ]; then
        _acc="$_new_acc"
      else
        break
      fi
    done <<EOF
$_bullets
EOF
    # If only the header fit (no bullets), drop the stanza entirely.
    if [ "$_acc" = "$_stanza_hdr" ]; then
      _rendered=""
    else
      _rendered="$_acc"
    fi
  fi
  # If everything got capped out, behave like the empty-bullets path.
  if [ -z "$_rendered" ]; then
    printf '%s\n' "$_expected_hdr" > "$_cache"
    return 0
  fi
  # C3 — pipe through pp_memory_redact_body so user-typed reason text that
  # contains secret literals ("ignore the AKIA..." etc.) is defanged before
  # it reaches every analyst LLM call.
  if [ -z "${_pp_redact_sourced:-}" ]; then
    # shellcheck disable=SC1091
    . "${PP_ROOT:-.}/lib/memory/redact.sh" 2>/dev/null && _pp_redact_sourced=1
  fi
  if type pp_memory_redact_body >/dev/null 2>&1; then
    _rendered=$(pp_memory_redact_body "$_rendered")
  fi
  # Write cache with header + body. Header lets us detect content drift
  # without re-running the full jq pipeline.
  printf '%s\n%s' "$_expected_hdr" "$_rendered" > "$_cache"
  printf '%s' "$_rendered"
}

# pp_dismiss_is_suppressed HASH
# Returns 0 if any active rule has hash == HASH; else 1.
# Active = deleted=false (LATEST line for the id) AND not-ttl-expired.
pp_dismiss_is_suppressed() {
  local _hash="${1:?pp_dismiss_is_suppressed requires a hash}"
  local _file
  _file=$(pp_dismiss_file_path) || return 1
  [ ! -f "$_file" ] && return 1
  local _now_ms
  _now_ms=$(date +%s)
  local _match
  _match=$(jq -s --arg h "$_hash" --arg now "$_now_ms" '
    group_by(.id) | map(last)
    | map(select(.deleted == false))
    | map(select(.ttl_days == null or (
        (.ts | fromdateiso8601) + (.ttl_days * 86400) > ($now | tonumber)
      )))
    | map(select(.hash == $h))
    | length
  ' "$_file")
  [ "${_match:-0}" -gt 0 ]
}

# pp_dismiss_enable ID
# Inverse of disable: appends a new line with deleted=false.
pp_dismiss_enable() {
  local _id="${1:?pp_dismiss_enable requires an id}"
  local _file
  _file=$(pp_dismiss_file_path) || return 1
  local _current
  _current=$(jq -c --arg id "$_id" 'select(.id == $id)' "$_file" 2>/dev/null | tail -1)
  [ -z "$_current" ] && { printf 'pp_dismiss: id %s not found\n' "$_id" >&2; return 1; }
  printf '%s\n' "$_current" \
    | jq -c '. + {deleted: false, deleted_reason: null}' \
    >> "$_file"
}

# pp_dismiss_ack HASH_PREFIX
# Records an explicit acknowledgement that this observation is useful and
# should NOT be auto-suppressed regardless of recurrence.
pp_dismiss_ack() {
  local _hash_prefix="${1:?pp_dismiss_ack requires a hash prefix}"
  local _file _id _ts
  _file=$(pp_dismiss_file_path) || return 1
  _id="a-$(date +%Y-%m-%d)-$(printf '%04x' $(( RANDOM * RANDOM % 65535 )))"
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -nc \
    --arg id "$_id" \
    --arg ts "$_ts" \
    --arg hash "$_hash_prefix" \
    '{
       id: $id, ts: $ts,
       reason_summary: "Acked — keep firing",
       scope: "project", lens_id: null,
       hash: $hash,
       deleted: false, deleted_reason: null,
       ttl_days: null, source: "ack"
     }' >> "$_file"
  printf '%s' "$_id"
}

# pp_dismiss_load_into_memory
# Rebuilds the memory_dismiss_rules table from the canonical JSONL.
# Idempotent (DELETE + bulk INSERT under one transaction).
# No-op if PP_MEMORY_ENABLE=0.
pp_dismiss_load_into_memory() {
  [ "${PP_MEMORY_ENABLE:-0}" = "1" ] || return 0
  local _file _db
  _file=$(pp_dismiss_file_path) || return 1
  if ! type pp_memory_db_path >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${PP_ROOT:-.}/lib/memory/store.sh" 2>/dev/null || return 1
  fi
  _db=$(pp_memory_db_path) || return 1
  [ ! -f "$_db" ] && return 0
  # Build CSV from latest-line-per-id of the JSONL (or empty if no file).
  local _csv=""
  if [ -f "$_file" ]; then
    _csv=$(jq -s -r '
      group_by(.id) | map(last)
      | .[] | [
          .id, .ts, .reason_summary, .scope, (.lens_id // ""), (.hash // ""),
          (.deleted | if . then 1 else 0 end),
          (.deleted_reason // ""), (.ttl_days // ""),
          .source
        ] | @csv
    ' "$_file" 2>/dev/null)
  fi
  # Atomic DELETE + INSERT in one transaction.
  {
    printf 'BEGIN;\nDELETE FROM memory_dismiss_rules;\n'
    if [ -n "$_csv" ]; then
      printf '%s\n' "$_csv" | while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        # Build a SQL INSERT — fields are already CSV-escaped by jq.
        printf 'INSERT INTO memory_dismiss_rules (id, ts, reason_summary, scope, lens_id, hash, deleted, deleted_reason, ttl_days, source) VALUES (%s);\n' "$_line"
      done
    fi
    printf 'COMMIT;\n'
  } | sqlite3 "$_db"
}

# pp_dismiss_auto_suppress
# Scans $PP_CACHE_DIR/cc-monitor-injected-hash-* across sessions, counts
# how many times each hash appears. Threshold + window from env. Acked
# hashes are skipped. Creates source=auto_suppress rules with ttl_days=7.
pp_dismiss_auto_suppress() {
  local _threshold="${PP_DISMISS_AUTO_THRESHOLD:-10}"
  case "$_threshold" in ''|*[!0-9]*) _threshold=10 ;; esac
  local _window="${PP_DISMISS_AUTO_WINDOW_DAYS:-30}"
  case "$_window" in ''|*[!0-9]*) _window=30 ;; esac
  local _file
  _file=$(pp_dismiss_file_path) || return 1
  # Gather acked-hash-prefixes set (these are the SHORT prefixes the user
  # supplied via pp_dismiss_ack; observation hashes are full 40-char sha1s).
  local _acked=""
  if [ -f "$_file" ]; then
    _acked=$(jq -r 'select(.source == "ack") | .hash' "$_file" 2>/dev/null)
  fi
  # I2 — Walk injected-hash files within the configured window only.
  # -mtime -N = modified within last N days (BSD + GNU + BusyBox).
  local _counts _f _content
  _counts=$(
    find "${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}" \
      -maxdepth 1 -name 'cc-monitor-injected-hash-*' -type f -mtime "-$_window" 2>/dev/null \
      | while IFS= read -r _f; do
          _content=$(cat "$_f" 2>/dev/null | tr -d '\n')
          [ -n "$_content" ] && printf '%s\n' "$_content"
        done \
      | sort | uniq -c | sort -nr
  )
  printf '%s\n' "$_counts" | while read -r _ct _hash; do
    [ -z "$_hash" ] && continue
    [ "${_ct:-0}" -lt "$_threshold" ] && continue
    # C4 — Skip if ANY acked prefix is a prefix of this hash. Direction
    # matters: acked stores PREFIX, observation is FULL hash. The old
    # `grep -qF "$_hash"` searched the full hash inside the prefix list,
    # which never matches when the prefix is shorter than the hash.
    local _skip=0 _ack_prefix
    if [ -n "$_acked" ]; then
      while IFS= read -r _ack_prefix; do
        [ -z "$_ack_prefix" ] && continue
        case "$_hash" in "$_ack_prefix"*) _skip=1; break ;; esac
      done <<EOF
$_acked
EOF
    fi
    [ "$_skip" = "1" ] && continue
    # C1 — Skip if already an active auto_suppress rule for this hash.
    # Must use latest-wins fold so an enable-after-disable cycle is honored.
    if [ -f "$_file" ]; then
      if jq -s -e --arg h "$_hash" '
        group_by(.id) | map(last)
        | map(select(.source == "auto_suppress" and .hash == $h and .deleted == false))
        | length > 0
      ' "$_file" >/dev/null 2>&1; then
        continue
      fi
    fi
    # Create auto-suppress rule.
    local _id _ts
    _id="d-$(date +%Y-%m-%d)-$(printf '%04x' $(( RANDOM * RANDOM % 65535 )))"
    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -nc \
      --arg id "$_id" --arg ts "$_ts" --arg hash "$_hash" \
      --argjson ct "$_ct" \
      '{
         id: $id, ts: $ts,
         reason_summary: "Auto-suppressed after \($ct) recurrences",
         scope: "project", lens_id: null,
         hash: $hash,
         deleted: false, deleted_reason: null,
         ttl_days: 7, source: "auto_suppress"
       }' >> "$_file"
  done
}
