#!/usr/bin/env bash
# Pair Polymath — single project-wide lock for ANY read-modify-write op.
# mkdir is atomic on POSIX. Wraps signals, activation recompute,
# eviction, pattern extraction. Append-only inserts via SQLite
# transactions don't need this (SQLite's own locking is sufficient).

pp_memory_lock() {
  local proj_dir="$1"
  local lockdir="$proj_dir/.maint.lock"
  local stale_s="${PP_MEMORY_LOCK_STALE_S:-300}"
  local timeout_s="${PP_MEMORY_LOCK_TIMEOUT_S:-30}"
  local waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    # Stale-takeover only when we can verify mtime. If both BSD-stat and
    # GNU-stat fail (busybox / no coreutils), we MUST NOT take over —
    # falling through to the timeout-based wait is the safe default.
    local mtime=""
    mtime=$(stat -f %m "$lockdir" 2>/dev/null) || \
    mtime=$(stat -c %Y "$lockdir" 2>/dev/null)
    if [ -n "$mtime" ]; then
      local age=$(( $(date +%s) - mtime ))
      if [ "$age" -gt "$stale_s" ]; then
        rm -rf "$lockdir" 2>/dev/null
        mkdir "$lockdir" 2>/dev/null && return 0
      fi
    fi
    waited=$((waited + 1))
    if [ "$waited" -gt "$timeout_s" ]; then
      printf 'pp_memory_lock: timeout waiting on %s\n' "$lockdir" >&2
      return 1
    fi
    sleep 1
  done
  return 0
}

pp_memory_unlock() {
  local proj_dir="$1"
  rmdir "$proj_dir/.maint.lock" 2>/dev/null || rm -rf "$proj_dir/.maint.lock" 2>/dev/null
}

# pp_memory_with_lock PROJ_DIR FUNC_NAME [ARGS...]
# Acquires lock, calls FUNC_NAME with the remaining args, always unlocks.
# NO eval — FUNC_NAME must be a defined shell function or external command.
pp_memory_with_lock() {
  local proj_dir="$1"
  shift
  [ "$#" -lt 1 ] && {
    printf 'pp_memory_with_lock: missing function name\n' >&2
    return 2
  }
  pp_memory_lock "$proj_dir" || return 1
  local rc=0
  "$@" || rc=$?
  pp_memory_unlock "$proj_dir"
  return "$rc"
}
