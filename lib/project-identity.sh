#!/usr/bin/env bash
# Pair Polymath — stable local project identity.
#
# Identity tuple:
#   real git top-level path + stable repo UUID + machine-local salt + plugin root
#
# The repo UUID lives in .git/pair-polymath-project-id when possible. If the
# git metadata directory is not writable, a state-dir mapping keyed by the real
# project root is used instead. The final project_id is salted and local to this
# machine; it is safe to store in local telemetry.

if [ -n "${_PP_PROJECT_IDENTITY_SOURCED:-}" ]; then
  if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    return 0
  else
    exit 0
  fi
fi
_PP_PROJECT_IDENTITY_SOURCED=1

_pp_project_state_dir() {
  printf '%s' "${PP_STATE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath}"
}

pp_project_hash() {
  local _body="${1:-}"
  local _h=""
  if command -v shasum >/dev/null 2>&1; then
    _h=$(printf '%s' "$_body" | shasum -a 256 2>/dev/null | cut -c1-64)
  elif command -v sha256sum >/dev/null 2>&1; then
    _h=$(printf '%s' "$_body" | sha256sum 2>/dev/null | cut -c1-64)
  elif command -v sha256 >/dev/null 2>&1; then
    _h=$(printf '%s' "$_body" | sha256 -q 2>/dev/null | cut -c1-64)
  elif command -v openssl >/dev/null 2>&1; then
    _h=$(printf '%s' "$_body" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' | cut -c1-64)
  elif command -v md5sum >/dev/null 2>&1; then
    _h=$(printf '%s' "$_body" | md5sum 2>/dev/null | cut -c1-32)
    _h="${_h}${_h}"
  elif command -v md5 >/dev/null 2>&1; then
    _h=$(printf '%s' "$_body" | md5 -q 2>/dev/null | cut -c1-32)
    _h="${_h}${_h}"
  fi
  [ -z "$_h" ] && _h="0000000000000000000000000000000000000000000000000000000000000000"
  printf '%s' "$_h"
}

pp_project_real_root() {
  local _cwd="${1:-$PWD}"
  local _root=""
  if git -C "$_cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
    _root=$(git -C "$_cwd" rev-parse --show-toplevel 2>/dev/null)
  fi
  [ -n "$_root" ] || _root="$_cwd"
  if [ -d "$_root" ]; then
    ( cd "$_root" 2>/dev/null && pwd -P ) || printf '%s' "$_root"
  else
    printf '%s' "$_root"
  fi
}

pp_project_plugin_root() {
  if [ -n "${PP_ROOT:-}" ] && [ -d "$PP_ROOT" ]; then
    ( cd "$PP_ROOT" 2>/dev/null && pwd -P ) || printf '%s' "$PP_ROOT"
  else
    ( cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P ) || printf ''
  fi
}

pp_project_machine_salt() {
  local _state _dir _salt_file _legacy_salt _salt
  _state=$(_pp_project_state_dir)
  _dir="${_state}/identity"
  _salt_file="${_dir}/machine-salt"
  _legacy_salt="${_state}/memory/.salt"

  if [ -s "$_legacy_salt" ]; then
    _salt=$(head -1 "$_legacy_salt" 2>/dev/null | LC_ALL=C tr -cd 'a-fA-F0-9')
    if [ -n "$_salt" ]; then
      mkdir -p "$_dir" 2>/dev/null || true
      if [ ! -s "$_salt_file" ]; then
        ( set -C; printf '%s\n' "$_salt" > "$_salt_file" ) 2>/dev/null || true
        chmod 600 "$_salt_file" 2>/dev/null || true
      fi
      printf '%s' "$_salt"
      return 0
    fi
  fi

  if [ ! -s "$_salt_file" ]; then
    mkdir -p "$_dir" 2>/dev/null || return 1
    chmod 700 "$_dir" 2>/dev/null || true
    _salt=$(pp_project_hash "$(hostname 2>/dev/null)-$(date +%s)-$$-${RANDOM:-0}")
    ( set -C; printf '%s\n' "$_salt" > "$_salt_file" ) 2>/dev/null || true
    chmod 600 "$_salt_file" 2>/dev/null || true
  fi
  _salt=$(head -1 "$_salt_file" 2>/dev/null | LC_ALL=C tr -cd 'a-fA-F0-9')
  [ -n "$_salt" ] || return 1
  printf '%s' "$_salt"
}

pp_project_git_uuid_file() {
  local _cwd="${1:-$PWD}" _git_dir=""
  git -C "$_cwd" rev-parse --git-dir >/dev/null 2>&1 || return 1
  _git_dir=$(git -C "$_cwd" rev-parse --git-common-dir 2>/dev/null \
            || git -C "$_cwd" rev-parse --git-dir 2>/dev/null \
            || printf '')
  [ -n "$_git_dir" ] || return 1
  case "$_git_dir" in
    /*) ;;
    *) _git_dir="$(pp_project_real_root "$_cwd")/$_git_dir" ;;
  esac
  printf '%s/pair-polymath-project-id' "$_git_dir"
}

pp_project_uuid() {
  local _cwd="${1:-$PWD}" _root _uuid_file="" _uuid="" _state _map_dir _root_hash _tmp
  _root=$(pp_project_real_root "$_cwd")

  _uuid_file=$(pp_project_git_uuid_file "$_cwd" 2>/dev/null || printf '')
  if [ -n "$_uuid_file" ] && [ -s "$_uuid_file" ]; then
    _uuid=$(head -1 "$_uuid_file" 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9._-')
    [ -n "$_uuid" ] && { printf '%s' "$_uuid"; return 0; }
  fi

  _uuid=""
  if command -v uuidgen >/dev/null 2>&1; then
    _uuid=$(uuidgen 2>/dev/null | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -cd 'a-z0-9-')
  fi
  [ -n "$_uuid" ] || _uuid=$(pp_project_hash "${_root}|$(pp_project_machine_salt 2>/dev/null)|$(date +%s)|$$|${RANDOM:-0}" | cut -c1-32)

  if [ -n "$_uuid_file" ]; then
    mkdir -p "$(dirname "$_uuid_file")" 2>/dev/null || true
    if [ -w "$(dirname "$_uuid_file")" ] || [ -w "$_uuid_file" ] 2>/dev/null; then
      _tmp=$(mktemp "${_uuid_file}.XXXXXX" 2>/dev/null || printf '')
      if [ -n "$_tmp" ]; then
        printf '%s\n' "$_uuid" > "$_tmp" 2>/dev/null \
          && mv "$_tmp" "$_uuid_file" 2>/dev/null \
          && chmod 600 "$_uuid_file" 2>/dev/null \
          && { printf '%s' "$_uuid"; return 0; }
        rm -f "$_tmp" 2>/dev/null || true
      fi
    fi
  fi

  _state=$(_pp_project_state_dir)
  _map_dir="${_state}/identity/projects"
  mkdir -p "$_map_dir" 2>/dev/null || return 1
  chmod 700 "$(dirname "$_map_dir")" "$_map_dir" 2>/dev/null || true
  _root_hash=$(pp_project_hash "$_root" | cut -c1-32)
  _uuid_file="${_map_dir}/${_root_hash}.id"
  if [ ! -s "$_uuid_file" ]; then
    ( set -C; printf '%s\n' "$_uuid" > "$_uuid_file" ) 2>/dev/null || true
    chmod 600 "$_uuid_file" 2>/dev/null || true
  fi
  _uuid=$(head -1 "$_uuid_file" 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9._-')
  [ -n "$_uuid" ] || return 1
  printf '%s' "$_uuid"
}

pp_project_id() {
  local _cwd="${1:-$PWD}" _root _uuid _salt _plugin
  _root=$(pp_project_real_root "$_cwd")
  _uuid=$(pp_project_uuid "$_cwd" 2>/dev/null || printf '')
  _salt=$(pp_project_machine_salt 2>/dev/null || printf '')
  _plugin=$(pp_project_plugin_root)
  [ -n "$_root" ] || return 1
  [ -n "$_uuid" ] || return 1
  [ -n "$_salt" ] || return 1
  pp_project_hash "${_root}|${_uuid}|${_salt}|${_plugin}" | cut -c1-16
}

pp_project_root_sha8() {
  pp_project_hash "$(pp_project_real_root "${1:-$PWD}")" | cut -c1-8
}

pp_project_identity_json() {
  local _cwd="${1:-$PWD}" _id _root _root_sha _plugin _uuid
  _id=$(pp_project_id "$_cwd" 2>/dev/null || printf '')
  _root=$(pp_project_real_root "$_cwd" 2>/dev/null || printf '')
  _root_sha=$(pp_project_hash "$_root" | cut -c1-8)
  _plugin=$(pp_project_plugin_root)
  _uuid=$(pp_project_uuid "$_cwd" 2>/dev/null || printf '')
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg project_id "$_id" \
      --arg project_root "$_root" \
      --arg project_root_sha8 "$_root_sha" \
      --arg repo_uuid "$_uuid" \
      --arg plugin_root "$_plugin" \
      '{project_id:$project_id,project_root:$project_root,project_root_sha8:$project_root_sha8,repo_uuid:$repo_uuid,plugin_root:$plugin_root}'
  else
    printf '{"project_id":"%s","project_root":"%s","project_root_sha8":"%s","repo_uuid":"%s","plugin_root":"%s"}\n' \
      "$_id" "$_root" "$_root_sha" "$_uuid" "$_plugin"
  fi
}
