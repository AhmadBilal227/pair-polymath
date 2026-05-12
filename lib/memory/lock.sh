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
#
# F8: lock release is wired to EXIT/INT/TERM traps so the lockdir is freed
# even if the inner function (or the shell hosting it) dies between the
# `mkdir` and the unconditional unlock. Previously, a SIGINT mid-flight
# would leave the lockdir until the 300s stale-takeover window elapsed.
#
# Trap interaction with bash:
#   - On RETURN from this function the EXIT trap fires only inside subshells.
#     We rely on it as a safety net; the explicit pp_memory_unlock at the
#     end of the happy path still releases for the normal case.
#   - INT/TERM traps catch the standard kill signals. The trap body must be
#     idempotent (pp_memory_unlock is — rmdir on a missing dir is a no-op).
pp_memory_with_lock() {
  local proj_dir="$1"
  shift
  [ "$#" -lt 1 ] && {
    printf 'pp_memory_with_lock: missing function name\n' >&2
    return 2
  }
  pp_memory_lock "$proj_dir" || return 1
  # Install signal traps that always release the lock. EXIT only fires
  # inside subshells (bash function return doesn't), so we still call the
  # explicit unlock below — INT/TERM are the ones we genuinely need.
  trap 'pp_memory_unlock "$proj_dir"' INT TERM
  local rc=0
  "$@" || rc=$?
  trap - INT TERM
  pp_memory_unlock "$proj_dir"
  return "$rc"
}
