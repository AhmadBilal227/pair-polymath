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
    # Stale-takeover only when we can verify mtime AS A VALID UNIX TIMESTAMP.
    # R3.8 — GNU stat first; BSD `stat -f` on Linux leaks fs-info to stdout.
    # R3.12 — additionally validate mtime is a numeric value in the
    # expected range (>= 1_000_000_000, i.e. year 2001+). On overlayfs we've
    # observed stat occasionally returning corrupted/zero values for
    # whiteout-influenced directories, which would falsely trigger stale
    # takeover and break the lock under high concurrency.
    local mtime=""
    mtime=$(stat -c %Y "$lockdir" 2>/dev/null) || \
    mtime=$(stat -f %m "$lockdir" 2>/dev/null)
    case "$mtime" in
      ''|*[!0-9]*) mtime="" ;;
      *) [ "$mtime" -lt 1000000000 ] && mtime="" ;;
    esac
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
# Run under pp_memory_with_lock. Reads the maintenance cycle counter from a
# plain file, increments by 1, writes it back. If the new value >= THRESHOLD,
# resets the counter to 0 and emits "TRIGGER" on stdout. Otherwise emits the
# new value.
#
# F6: was previously a read-modify-write OUTSIDE any lock in bin/statusline.sh,
# so two concurrent statuslines could both observe N-1, both write N, both
# trigger maintenance.
#
# R3.11 — STORAGE MOVED FROM SQLITE TO PLAIN FILE. The previous SQLite-backed
# version failed on CI (24-job concurrency test on Linux/Docker overlayfs):
# SQLite WAL mode relies on shared-memory (-shm) mmap, which has reliability
# issues on overlayfs and some network filesystems. Concurrent readers saw
# STALE counter values across separate sqlite3 process invocations even
# under the mkdir-lock (the mkdir-lock serialized our shell code, but WAL
# visibility between separate sqlite3 invocations was not guaranteed).
# Diagnostic on CI run 25755301220 showed 10 duplicate counter reads out of
# 24 increments — the lock was holding, but the data layer was lying.
#
# Plain file under the mkdir-lock has no such failure mode: single-writer,
# single-reader, all under the same lock, no FS caching games.
_pp_memory_increment_maint_counter_locked() {
  local proj_dir="$1" threshold="$2"
  [ -d "$proj_dir" ] || { printf 'NOOP'; return 0; }
  # Validate threshold (was already SQL-quoted in v1; preserved for safety).
  case "$threshold" in
    ''|*[!0-9]*) threshold=12 ;;
  esac
  local counter_file="$proj_dir/maintenance-counter"
  local cur
  if [ -f "$counter_file" ]; then
    cur=$(cat "$counter_file" 2>/dev/null || printf '')
  else
    cur=''
  fi
  case "$cur" in
    ''|*[!0-9]*) cur=0 ;;
  esac
  local nxt=$((cur + 1))
  # R3.11 v3 — atomic write via mktemp + mv. We DROPPED the explicit sync
  # call from v2 because empirical Docker stress testing showed it INCREASED
  # F6 flakiness (system-wide sync under 24-way concurrency saturates I/O
  # and pushes individual ops past the lock timeout window). The real fix
  # is in pp_memory_lock (R3.12 — guard against bogus mtime values
  # triggering spurious stale-takeover). mv on the same FS is atomic per
  # POSIX, which is enough as long as the mkdir-lock truly serializes the
  # critical section.
  local tmp
  tmp=$(mktemp "$counter_file.XXXXXX") || return 1
  if [ "$nxt" -ge "$threshold" ]; then
    printf '0' > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$counter_file" || { rm -f "$tmp"; return 1; }
    printf 'TRIGGER'
  else
    printf '%s' "$nxt" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$counter_file" || { rm -f "$tmp"; return 1; }
    printf '%s' "$nxt"
  fi
  return 0
}
