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

PP_ROOT="${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/config.sh" 2>/dev/null || true

# Fast no-op path after config load: persistent PP_OAR_ENABLE in user.env
# must be visible to Claude's SessionEnd hook process.
if [ "${PP_OAR_ENABLE:-0}" != "1" ]; then
  exit 0
fi

# Read SessionEnd event JSON from stdin
_input=$(cat 2>/dev/null || printf '{}')
_session_id=$(printf '%s' "$_input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$_session_id" ] && exit 0
_session_id=$(pp_sanitize_session_id "$_session_id")

# v0.5.2: pp_extract_citations_from_text — used to populate cited_paths +
# cited_symbols in the pending row (C2 fix path A from plan addendum).
# shellcheck disable=SC1091
. "$PP_ROOT/lib/citations.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$PP_ROOT/lib/prompt-contract.sh" 2>/dev/null || true
# GPT review #2: surface silent degradation if the citations lib failed to
# source. Without this, missing helper → empty cite arrays silently → OAR
# labeler's referenced-detection rate gets biased toward zero exactly the
# way the pre-mortem warned about.
if ! command -v pp_extract_citations_from_text >/dev/null 2>&1; then
  printf 'pair-polymath session-end: pp_extract_citations_from_text unavailable; cite arrays will be empty\n' >&2
fi

_prompt_versions_json="{}"
if command -v pp_prompt_contract_versions_json >/dev/null 2>&1; then
  _prompt_versions_json=$(pp_prompt_contract_versions_json 2>/dev/null || printf '{}')
fi
printf '%s' "$_prompt_versions_json" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || _prompt_versions_json="{}"

_now=$(date +%s)
_cache_dir="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
_pending_file="${_cache_dir}/oar-pending.jsonl"
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

_pp_hash12() {
  local _h=""
  if command -v shasum >/dev/null 2>&1; then
    _h=$(shasum -a 256 2>/dev/null | cut -c1-12)
  elif command -v sha256sum >/dev/null 2>&1; then
    _h=$(sha256sum 2>/dev/null | cut -c1-12)
  elif command -v sha256 >/dev/null 2>&1; then
    _h=$(sha256 -q 2>/dev/null | cut -c1-12)
  elif command -v md5sum >/dev/null 2>&1; then
    _h=$(md5sum 2>/dev/null | cut -c1-12)
  elif command -v md5 >/dev/null 2>&1; then
    _h=$(md5 -q 2>/dev/null | cut -c1-12)
  fi
  [ -z "$_h" ] && _h="000000000000"
  printf '%s' "$_h"
}

# Walk this session's injected-hash files
find "$_cache_dir" -maxdepth 1 \
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
    #
    # GPT review #5: defense-in-depth sanitize the lens id before
    # constructing a filesystem path. The lens registry already validates
    # IDs at load time, but a path containing `/` or whitespace here would
    # escape PP_CACHE_DIR and hit the wrong file. Reject those lenses
    # (skip the row entirely; better than mis-reading a sibling lens's
    # observation).
    case "$_lens" in
      *[/[:space:]]*) continue ;;
    esac
    _obs_file="${_cache_dir}/cc-monitor-${_session_id}-${_lens}.txt"
    _body=""
    if [ -f "$_obs_file" ]; then
      # Analyst line format (see bin/statusline.sh:1162): `LENS_TYPE: title|||body`.
      # Body = everything after the first `|||` separator on line 1. We use
      # `head -1` then `cut`/`sed` to extract — `awk -F '\\|\\|\\|'` would
      # work too, but cut is simpler since we only want the tail half.
      #
      # GPT review #12 + code-reviewer minor #3: strip CRLF. If a user
      # manually edited the obs file in a Windows editor, head -1 keeps
      # the \r which then lands in body + gets stored in pending row JSON.
      _line=$(head -1 "$_obs_file" 2>/dev/null | tr -d '\r')
      case "$_line" in
        *'|||'*)
          # Strip the shortest prefix through the first `|||` (parameter
          # expansion `#` is shortest-match-from-left, NOT greedy — that's
          # `##`). So a body that itself contains `|||` is preserved.
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

    # GPT review #1: surface jq write failures. The pre-mortem flagged
    # silent data loss as the most likely v0.5.2 failure mode. Without
    # this, a permission/disk/quota error → pending row silently dropped
    # → operator sees fewer labeled rows than expected → can't tell if
    # the metric is broken or just nobody acted. Telemetry stays
    # fail-open (hook returns 0), but the operator gets a stderr signal.
    if ! jq -nc \
      --arg sid "$_session_id" \
      --arg lens "$_lens" \
      --arg hash "$_hash" \
      --arg inject_ts "$_inject_iso" \
      --argjson scan_at "$_scan_at" \
      --arg body "$_body" \
      --argjson cited_paths "$_cited_paths_json" \
      --argjson cited_symbols "$_cited_symbols_json" \
      --argjson prompt_versions "$_prompt_versions_json" \
      '{session_id: $sid, lens: $lens, hash: $hash, inject_ts: $inject_ts, scan_at_epoch: $scan_at, attempts: 0, status: "pending", body: $body, cited_paths: $cited_paths, cited_symbols: $cited_symbols, prompt_versions: $prompt_versions}' \
      >> "$_pending_file" 2>/dev/null; then
      printf 'pair-polymath session-end: failed to append pending row for lens=%s (check %s permissions)\n' \
        "$_lens" "$_pending_file" >&2
    fi
  done

# SILENT-v2 lenses never get an injected-hash marker because no observation
# was shown to the user. Bridge their verdict sidecars into OAR pending rows
# so history can distinguish "correctly silent" from "missing data".
find "$_cache_dir" -maxdepth 1 \
  -name "cc-monitor-${_session_id}-*-verdict.txt" -type f 2>/dev/null \
  | while IFS= read -r _vf; do
    grep -qxF '# v2: outcome=silent' "$_vf" 2>/dev/null || continue
    _base=$(basename "$_vf")
    _lens="${_base#cc-monitor-${_session_id}-}"
    _lens="${_lens%-verdict.txt}"
    case "$_lens" in
      ''|*[/[:space:]]*) continue ;;
    esac
    _reason=$(grep -E '^# v2: silent_reason=' "$_vf" 2>/dev/null \
      | head -1 | sed 's/^# v2: silent_reason=//')
    [ -z "$_reason" ] && _reason="unspecified"
    case "$_reason" in *[!A-Za-z0-9_.:-]*) _reason="unspecified" ;; esac

    _inject_epoch=$(_pp_stat_mtime "$_vf")
    case "$_inject_epoch" in ''|*[!0-9]*|0) _inject_epoch="$_now" ;; esac
    _inject_iso=$(date -u -r "$_inject_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$_inject_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u +%Y-%m-%dT%H:%M:%SZ)
    _hash=$( { printf 'silent:%s:%s:' "$_lens" "$_reason"; cat "$_vf" 2>/dev/null; } | _pp_hash12)

    if ! jq -nc \
      --arg sid "$_session_id" \
      --arg lens "$_lens" \
      --arg hash "$_hash" \
      --arg inject_ts "$_inject_iso" \
      --argjson scan_at "$_inject_epoch" \
      --arg reason "$_reason" \
      --argjson prompt_versions "$_prompt_versions_json" \
      '{session_id: $sid, lens: $lens, hash: $hash, inject_ts: $inject_ts, scan_at_epoch: $scan_at, attempts: 0, status: "pending", body: "", cited_paths: [], cited_symbols: [], outcome: "silent", silent_reason: $reason, prompt_versions: $prompt_versions}' \
      >> "$_pending_file" 2>/dev/null; then
      printf 'pair-polymath session-end: failed to append silent pending row for lens=%s (check %s permissions)\n' \
        "$_lens" "$_pending_file" >&2
    fi
  done

exit 0
