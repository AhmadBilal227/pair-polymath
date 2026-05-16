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
# v0.5.2: pp_extract_citations_from_text — used to populate cited_paths +
# cited_symbols in the pending row (C2 fix path A from plan addendum).
# shellcheck disable=SC1091
. "$PP_ROOT/lib/citations.sh" 2>/dev/null || true

_now=$(date +%s)
_pending_file="${PP_CACHE_DIR:-$HOME/.claude/cache}/oar-pending.jsonl"
mkdir -p "$(dirname "$_pending_file")" 2>/dev/null || exit 0

# R10 (v0.5.1 Round-2): inject_ts must reflect when the observation was
# actually INJECTED, not SessionEnd time. The hash file is written at
# injection time (hooks/inject-monitor-insight.sh), so its mtime is the
# closest proxy available without adding a separate timestamp file.
# Use _PP_STAT_FLAVOR if probed; otherwise fall back to BSD-style stat
# (macOS default) then GNU-style.
_pp_stat_mtime() {
  local _path="${1:-}"
  [ -f "$_path" ] || { printf '0'; return; }
  local _m=""
  case "${_PP_STAT_FLAVOR:-}" in
    bsd) _m=$(stat -f %m "$_path" 2>/dev/null) ;;
    gnu) _m=$(stat -c %Y "$_path" 2>/dev/null) ;;
    *)
      # Probe order matters: BSD `stat -f` on GNU Linux is `--file-system`
      # which exits 0 with garbage (mount-point string) → silently masks
      # the GNU branch. Try GNU first and require numeric output before
      # accepting; fall back to BSD only if GNU returns nothing usable.
      _m=$(stat -c %Y "$_path" 2>/dev/null)
      case "$_m" in ''|*[!0-9]*) _m="" ;; esac
      if [ -z "$_m" ]; then
        _m=$(stat -f %m "$_path" 2>/dev/null)
      fi
      ;;
  esac
  case "$_m" in ''|*[!0-9]*) _m="0" ;; esac
  printf '%s' "$_m"
}

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
    _inject_epoch=$(_pp_stat_mtime "$_f")
    case "$_inject_epoch" in ''|*[!0-9]*|0) _inject_epoch="$_now" ;; esac
    _inject_iso=$(date -u -r "$_inject_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$_inject_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u +%Y-%m-%dT%H:%M:%SZ)
    _scan_at=$(( _inject_epoch + _window_s ))

    # v0.5.2 (Task 2, plan addendum C2 fix path A): also capture the
    # observation body + cited paths/symbols so the labeler (Task 8) is a
    # pure function of the pending row. The observation file is the
    # per-lens cache that statusline.sh writes alongside the hash file —
    # filename pattern matches the v0.5.1 convention used at
    # bin/statusline.sh:1064 (PP_CACHE_LENS).
    _obs_file="${PP_CACHE_DIR:-$HOME/.claude/cache}/cc-monitor-${_session_id}-${_lens}.txt"
    _body=""
    if [ -f "$_obs_file" ]; then
      # Analyst line format (see bin/statusline.sh:1162): `LENS_TYPE: title|||body`.
      # Body = everything after the first `|||` separator on line 1. We use
      # `head -1` then `cut`/`sed` to extract — `awk -F '\\|\\|\\|'` would
      # work too, but cut is simpler since we only want the tail half.
      _line=$(head -1 "$_obs_file" 2>/dev/null)
      case "$_line" in
        *'|||'*)
          # Strip everything through the first `|||` (greediest single
          # match) so a body that itself contains `|||` is preserved.
          _body="${_line#*|||}"
          ;;
        *)
          # No `|||` separator: treat the whole line as body (defensive —
          # shouldn't happen in production since malformed analyst output
          # is rejected by the regex gate at bin/statusline.sh:1162).
          _body="$_line"
          ;;
      esac
    fi

    # Citation extraction. Empty body → empty allowlists → empty JSON arrays.
    pp_extract_citations_from_text "$_body" 2>/dev/null || true
    _cited_paths_json=$(printf '%s' "${_pp_valid_paths:-}" \
      | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null \
      || printf '[]')
    _cited_symbols_json=$(printf '%s' "${_pp_valid_symbols:-}" \
      | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null \
      || printf '[]')

    jq -nc \
      --arg sid "$_session_id" \
      --arg lens "$_lens" \
      --arg hash "$_hash" \
      --arg inject_ts "$_inject_iso" \
      --argjson scan_at "$_scan_at" \
      --arg body "$_body" \
      --argjson cited_paths "$_cited_paths_json" \
      --argjson cited_symbols "$_cited_symbols_json" \
      '{session_id: $sid, lens: $lens, hash: $hash, inject_ts: $inject_ts, scan_at_epoch: $scan_at, attempts: 0, status: "pending", body: $body, cited_paths: $cited_paths, cited_symbols: $cited_symbols}' \
      >> "$_pending_file" 2>/dev/null || true
  done

exit 0
