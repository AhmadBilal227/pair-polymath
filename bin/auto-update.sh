#!/usr/bin/env bash
# v0.5.5 — auto-update worker. Invoked by launchd / systemd / cron on a
# schedule set by `polymath auto-update enable`. Runs `polymath update --yes`,
# appends a structured log line, and exits 0 even on failure so the
# scheduler doesn't disable itself (failures show up in the log and in
# `polymath auto-update status`).
#
# Safe to run by hand: it just logs an extra line.

set -u
export LC_ALL=C
umask 077

PP_ROOT="${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
PP_HOME="${PP_HOME:-$CLAUDE_DIR/pair-polymath}"
LOG_DIR="${PP_AUTO_UPDATE_LOG_DIR:-$PP_HOME/logs}"
LOG="${PP_AUTO_UPDATE_LOG:-$LOG_DIR/auto-update.log}"
LOCK="${PP_AUTO_UPDATE_LOCK:-${TMPDIR:-/tmp}/pp-auto-update.lock}"

mkdir -p "$LOG_DIR" 2>/dev/null || true

# Rotate at ~64 KB. Single rotation, no compression — auto-update fires once
# per day, so a single rotation buys us roughly two years of history.
if [ -f "$LOG" ]; then
  _size=$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')
  if [ "${_size:-0}" -gt 65536 ]; then
    mv -f "$LOG" "${LOG}.1" 2>/dev/null || true
  fi
fi

# Atomic single-instance lock (mkdir-based; Linux-only flock unavailable on
# macOS by default). Stale-lock reclaim at 1 hour matches the worst-case
# upstream fetch + install runtime; tune via PP_AUTO_UPDATE_LOCK_STALE_S.
_now=$(date +%s)
_stale_after="${PP_AUTO_UPDATE_LOCK_STALE_S:-3600}"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -d "$LOCK" ]; then
    # Probe lock mtime; if older than stale-after, reclaim.
    if [ "$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo 0)" -lt "$((_now - _stale_after))" ]; then
      rm -rf "$LOCK" 2>/dev/null || true
      mkdir "$LOCK" 2>/dev/null || exit 0
    else
      # Another auto-update already running. Log and bail.
      printf '%s\tSKIP\tlock held: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOCK" >>"$LOG" 2>/dev/null
      exit 0
    fi
  fi
fi
trap 'rm -rf "$LOCK" 2>/dev/null; true' EXIT

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_out=$(bash "$PP_ROOT/bin/polymath" update --yes 2>&1)
rc=$?
finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Single-line summary; keep the full output below it for forensic value.
if [ "$rc" -eq 0 ]; then
  printf '%s\tOK\t%s\trc=%d\n' "$started" "$finished" "$rc" >>"$LOG"
else
  printf '%s\tFAIL\t%s\trc=%d\n' "$started" "$finished" "$rc" >>"$LOG"
fi
# Indented body — easy to skip when tail-grepping for the summary marker.
printf '%s\n' "$_out" | sed 's/^/    /' >>"$LOG"
printf '%s\n' "----" >>"$LOG"

# Exit 0 unconditionally — failures should not cause the scheduler to mark
# the job broken. Operator sees failure via `polymath auto-update status`.
exit 0
