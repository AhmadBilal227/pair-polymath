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
  [ ! -f "$_file" ] && return 0
  local _now_ms
  _now_ms=$(date +%s)
  jq -r --arg scope "$_scope_filter" --arg now "$_now_ms" '
    select(.deleted == false)
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
  _line=$(jq -c "select(.id == \"$_id\")" "$_file" 2>/dev/null | tail -1)
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
  _current=$(jq -c "select(.id == \"$_id\")" "$_file" 2>/dev/null | tail -1)
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
# Cache invalidation: cache mtime < source JSONL mtime -> re-render.
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
  # If no source rules, emit empty + clear cache.
  if [ ! -f "$_file" ]; then
    : > "$_cache"
    return 0
  fi
  # Cache hit when cache mtime >= source mtime.
  if [ -f "$_cache" ]; then
    local _src_m _cache_m
    if stat -c %Y /dev/null >/dev/null 2>&1; then
      _src_m=$(stat -c %Y "$_file" 2>/dev/null || echo 0)
      _cache_m=$(stat -c %Y "$_cache" 2>/dev/null || echo 0)
    else
      _src_m=$(stat -f %m "$_file" 2>/dev/null || echo 0)
      _cache_m=$(stat -f %m "$_cache" 2>/dev/null || echo 0)
    fi
    if [ "$_cache_m" -ge "$_src_m" ]; then
      cat "$_cache"
      return 0
    fi
  fi
  # Re-render: filter active, sort manual-first then newest-first,
  # dedup exact reason_summary, take 8, truncate per-bullet.
  local _now_ms _rendered
  _now_ms=$(date +%s)
  _rendered=$(jq -r --arg now "$_now_ms" '
    select(.deleted == false)
    | select(.ttl_days == null or (
        (.ts | fromdateiso8601) + (.ttl_days * 86400) > ($now | tonumber)
      ))
    | "\(if .source == "manual" then "0" else "1" end)\t\(.ts)\t\(.reason_summary)"
  ' "$_file" \
    | sort -t "$(printf '\t')" -k1,1 -k2,2r \
    | awk -F'\t' '!seen[$3]++ {print "- " $3}' \
    | head -8)
  # Per-bullet truncate at 200 chars (word boundary).
  _rendered=$(printf '%s\n' "$_rendered" | awk '{
    if (length($0) > 200) {
      s = substr($0, 1, 200)
      sub(/ [^ ]*$/, "", s)
      print s
    } else { print }
  }')
  # Total-bytes cap: keep whole lines that fit within _max bytes.
  local _byte_count
  _byte_count=$(printf '%s' "$_rendered" | LC_ALL=C wc -c | tr -d ' ')
  if [ "$_byte_count" -gt "$_max" ]; then
    local _acc _line _new_acc
    _acc=""
    while IFS= read -r _line; do
      if [ -z "$_acc" ]; then
        _new_acc="$_line"
      else
        _new_acc="${_acc}
${_line}"
      fi
      if [ "$(printf '%s' "$_new_acc" | LC_ALL=C wc -c | tr -d ' ')" -le "$_max" ]; then
        _acc="$_new_acc"
      else
        break
      fi
    done <<EOF
$_rendered
EOF
    _rendered="$_acc"
  fi
  printf '%s' "$_rendered" > "$_cache"
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
  _current=$(jq -c "select(.id == \"$_id\")" "$_file" 2>/dev/null | tail -1)
  [ -z "$_current" ] && { printf 'pp_dismiss: id %s not found\n' "$_id" >&2; return 1; }
  printf '%s\n' "$_current" \
    | jq -c '. + {deleted: false, deleted_reason: null}' \
    >> "$_file"
}
