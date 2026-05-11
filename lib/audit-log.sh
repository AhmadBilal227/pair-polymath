#!/usr/bin/env bash
# Pair Polymath — installer audit log. Sourced by bin/install.sh.
# Append-only JSONL at $CLAUDE_DIR/pair-polymath/install.log.
# Each line: {ts, action, command, exit_code, stderr_tail}
#
# audit_log ACTION COMMAND EXIT_CODE [STDERR_TAIL]
# Example:
#   audit_log dep-install "brew install jq" 0 ""
#   audit_log settings-merge "jq ... > settings.json" 0 ""
#   audit_log smoke-test "cat fixture | statusline.sh" 1 "syntax error near line 47"

PP_AUDIT_LOG="${PP_AUDIT_LOG:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath/install.log}"

audit_log() {
  local action="$1" command="$2" exit_code="${3:-0}" stderr_tail="${4:-}"
  # Dry-run produces zero FS changes — including no audit-log writes.
  # The installer's [DRY-RUN] stdout lines are the audit trail in this mode.
  if [ "${PP_DRY_RUN:-0}" = "1" ]; then
    return 0
  fi
  local audit_dir
  audit_dir="$(dirname "$PP_AUDIT_LOG")"
  mkdir -p "$audit_dir" 2>/dev/null || return 0  # never fail an install over the log

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Use jq to build the JSON safely (escapes embedded quotes / newlines).
  local entry
  if command -v jq >/dev/null 2>&1; then
    entry=$(jq -cn \
      --arg ts "$ts" \
      --arg action "$action" \
      --arg command "$command" \
      --argjson exit_code "$exit_code" \
      --arg stderr_tail "$stderr_tail" \
      '{ts:$ts, action:$action, command:$command, exit_code:$exit_code, stderr_tail:$stderr_tail}' \
      2>/dev/null) || entry=""
  fi
  if [ -z "$entry" ]; then
    # Fallback when jq isn't available yet (very early in install) OR jq failed.
    # Minimal escaping for embedded backslashes / double-quotes / newlines.
    local esc_cmd esc_stderr
    esc_cmd=$(printf '%s' "$command" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    esc_stderr=$(printf '%s' "$stderr_tail" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    entry=$(printf '{"ts":"%s","action":"%s","command":"%s","exit_code":%s,"stderr_tail":"%s"}' \
      "$ts" "$action" "$esc_cmd" "$exit_code" "$esc_stderr")
  fi
  printf '%s\n' "$entry" >> "$PP_AUDIT_LOG" 2>/dev/null || true
}
