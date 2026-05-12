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
    # Stale-takeover only when we can verify mtime. If both GNU-stat and
    # BSD-stat fail (busybox / no coreutils), we MUST NOT take over —
    # falling through to the timeout-based wait is the safe default.
    # R3.8 — GNU first; BSD `stat -f` on Linux leaks fs-info to stdout on
    # failure and would poison `$mtime` to a non-numeric, breaking stale
    # detection silently.
    local mtime=""
    mtime=$(stat -c %Y "$lockdir" 2>/dev/null) || \
    mtime=$(stat -f %m "$lockdir" 2>/dev/null)
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
  # R3.5 (revised after GPT meta-review): run the inner function inside a
  # subshell so the trap scope is naturally isolated from the caller. The
  # earlier `trap -p` save+restore approach was brittle — bash's trap -p
  # output is quoting-fragile and eval'ing it back can mis-parse handlers
  # that contain semicolons or newlines, especially across bash versions.
  #
  # Subshell semantics are safe for every current caller: all inner functions
  # (recompute_scores, extract_patterns_inner, evict_inner, signals taggers,
  # increment_maint_counter_locked) communicate via side effects (SQLite
  # writes, filesystem) or stdout — none mutate parent-shell variables.
  #
  # The subshell's INT/TERM trap releases the lock if the inner function is
  # killed mid-flight. The unconditional pp_memory_unlock after the subshell
  # is the happy-path release. unlock is idempotent (rmdir on missing dir
  # is a noop) so a double-release is harmless.
  local rc=0
  # The `|| _rc=$?` is critical under `set -e` (bats enables it): without
  # it, a failing inner function would let set -e abort the subshell at the
  # call-site, skipping our explicit `exit $_rc` and losing the real status.
  # Using `|| _rc=$?` defangs set -e for that one call site only.
  (
    trap 'pp_memory_unlock "$proj_dir"; exit 130' INT TERM
    _rc=0
    "$@" || _rc=$?
    exit "$_rc"
  )
  rc=$?
  pp_memory_unlock "$proj_dir"
  return "$rc"
}

# _pp_memory_increment_maint_counter_locked PROJ_DIR THRESHOLD
# Run under pp_memory_with_lock. Reads cycle_state.maintenance_cycle_counter,
# increments by 1, and writes it back. If the new value >= THRESHOLD, ALSO
# resets the counter to 0 atomically (inside the same lock + same SQL run)
# and emits "TRIGGER" on stdout. Otherwise emits the new value.
#
# F6: was previously a read-modify-write OUTSIDE any lock in bin/statusline.sh,
# so two concurrent statuslines could both observe N-1, both write N, both
# trigger maintenance. The maintenance functions themselves take the lock,
# but the cycle counter decision happened before that. Pulling it inside
# pp_memory_with_lock serializes the decision atomically.
_pp_memory_increment_maint_counter_locked() {
  local proj_dir="$1" threshold="$2"
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || { printf 'NOOP'; return 0; }
  # Validate threshold so we don't interpolate hostile values into SQL.
  case "$threshold" in
    ''|*[!0-9]*) threshold=12 ;;
  esac
  local cur
  cur=$(sqlite3 -cmd "PRAGMA trusted_schema = 1;" "$db" \
    "SELECT value FROM cycle_state WHERE key='maintenance_cycle_counter';" 2>/dev/null)
  case "$cur" in
    ''|*[!0-9]*) cur=0 ;;
  esac
  local nxt=$((cur + 1))
  if [ "$nxt" -ge "$threshold" ]; then
    sqlite3 -cmd "PRAGMA trusted_schema = 1;" "$db" \
      "INSERT OR REPLACE INTO cycle_state(key,value) VALUES('maintenance_cycle_counter','0');" \
      2>/dev/null || return 1
    printf 'TRIGGER'
  else
    sqlite3 -cmd "PRAGMA trusted_schema = 1;" "$db" \
      "INSERT OR REPLACE INTO cycle_state(key,value) VALUES('maintenance_cycle_counter','$nxt');" \
      2>/dev/null || return 1
    printf '%s' "$nxt"
  fi
  return 0
}
