#!/usr/bin/env bash
# SessionEnd hook scaffold. v0.5.1 — OAR (Observation Audit Replay) prerequisite.
#
# When PP_OAR_ENABLE=0 (default): immediate no-op. Zero side effects.
# When PP_OAR_ENABLE=1: for each cc-monitor-injected-hash-* for this session,
# write an oar-pending JSONL record with hash + inject-time + scan-at timestamp.
#
# Per-lens scan window:
#   ENGINEERING / SECURITY / PERF_FINOPS    → 24h
#   UX_DESIGN                               → 48h
#   PRODUCT_BIZ / STRATEGIC_FOUNDER         → 7d
#   *                                       → 24h (fallback)

set -u
umask 077

# Fast no-op path — keep this gate at the top to honor the <50ms latency budget.
if [ "${PP_OAR_ENABLE:-0}" != "1" ]; then
  exit 0
fi

# Read SessionEnd event JSON from stdin
_input=$(cat 2>/dev/null || printf '{}')
_session_id=$(printf '%s' "$_input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$_session_id" ] && exit 0

PP_ROOT="${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/config.sh" 2>/dev/null || true

_now=$(date +%s)
_now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_pending_file="${PP_CACHE_DIR:-$HOME/.claude/cache}/oar-pending.jsonl"
mkdir -p "$(dirname "$_pending_file")" 2>/dev/null || exit 0

# Walk this session's injected-hash files
find "${PP_CACHE_DIR:-$HOME/.claude/cache}" -maxdepth 1 \
  -name "cc-monitor-injected-hash-${_session_id}-*.txt" -type f 2>/dev/null \
  | while IFS= read -r _f; do
    _lens=$(basename "$_f" | sed -E "s/^cc-monitor-injected-hash-${_session_id}-//; s/\.txt$//")
    _hash=$(head -1 "$_f" 2>/dev/null | tr -d ' \n')
    [ -z "$_hash" ] && continue
    case "$_lens" in
      ENGINEERING|SECURITY|PERF_FINOPS) _window_s=86400 ;;
      UX_DESIGN) _window_s=172800 ;;
      PRODUCT_BIZ|STRATEGIC_FOUNDER) _window_s=604800 ;;
      *) _window_s=86400 ;;
    esac
    _scan_at=$(( _now + _window_s ))
    jq -nc \
      --arg sid "$_session_id" \
      --arg lens "$_lens" \
      --arg hash "$_hash" \
      --arg inject_ts "$_now_iso" \
      --argjson scan_at "$_scan_at" \
      '{session_id: $sid, lens: $lens, hash: $hash, inject_ts: $inject_ts, scan_at_epoch: $scan_at, status: "pending"}' \
      >> "$_pending_file" 2>/dev/null || true
  done

exit 0
