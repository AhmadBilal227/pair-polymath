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
