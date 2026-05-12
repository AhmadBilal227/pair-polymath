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
    # Check stale lock
    local age
    age=$(($(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo 0)))
    if [ "$age" -gt "$stale_s" ]; then
      rm -rf "$lockdir" 2>/dev/null
      mkdir "$lockdir" 2>/dev/null && return 0
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

# pp_memory_with_lock PROJ_DIR CMD
# Acquire lock, eval CMD, always unlock (success or failure).
pp_memory_with_lock() {
  local proj_dir="$1"
  local cmd="$2"
  pp_memory_lock "$proj_dir" || return 1
  local rc=0
  eval "$cmd" || rc=$?
  pp_memory_unlock "$proj_dir"
  return "$rc"
}
