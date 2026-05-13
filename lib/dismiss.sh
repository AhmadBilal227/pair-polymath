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
