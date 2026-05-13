#!/usr/bin/env bash
# lib/tool-summary.sh — render a tool-call JSON array as a human-readable
# one-line-per-call block for analyst context.
#
# Owns: the JSON → text rendering for the "what did Claude actually DO
# since last cycle" signal. The structured JSON comes from
# pp_transcript_tool_calls (lib/transcript.sh); this module formats it.
#
# Public function:
#   pp_tool_summary_render <json_array_string>   → stdout: formatted text
#
# Bash 3.2-portable. Uses jq for parsing. Runs the output through the
# project's pp_redact_secrets (or transcript.sh's awk-fallback) so a
# secret-shaped path or tool_result snippet can't reach the LLM call.

if [ -n "${_PP_TOOL_SUMMARY_SOURCED:-}" ]; then return 0; fi
_PP_TOOL_SUMMARY_SOURCED=1

# Pull in the redactor chain from lib/transcript.sh (which itself prefers
# pp_redact_secrets from lib/grounding.sh, falling back to its awk-based
# built-in). This keeps redaction policy single-sourced.
if [ -z "${_PP_TRANSCRIPT_SOURCED:-}" ]; then
  _pp_ts_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -r "${_pp_ts_self_dir}/transcript.sh" ]; then
    # shellcheck source=transcript.sh
    . "${_pp_ts_self_dir}/transcript.sh" 2>/dev/null || true
  fi
fi

# pp_tool_summary_render <json_string>
# Empty array, missing input, or jq absent → "(no recent tool calls)".
# Unified empty-signal so analysts get one canonical "nothing to see".
pp_tool_summary_render() {
  local _json="${1:-}"
  if [ -z "$_json" ]; then
    printf '(no recent tool calls)'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '(no recent tool calls)'
    return 0
  fi

  if ! printf '%s' "$_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '(no recent tool calls)'
    return 0
  fi
  local _len
  _len=$(printf '%s' "$_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "$_len" = "0" ]; then
    printf '(no recent tool calls)'
    return 0
  fi

  # Defense-in-depth cap (GPT review-code C2): the canonical cap lives in
  # pp_transcript_tool_calls, but if a downstream caller in Phase 2 passes
  # an uncapped array, the renderer applies the same cap as a safety net.
  local _max="${PP_TOOL_SUMMARY_MAX:-20}"
  local _lines
  _lines=$(printf '%s' "$_json" | jq -r --argjson n "$_max" '
    (if length <= $n then . else .[length - $n:] end)[]
    | (
        ((.tool // "?") | .[0:6])
        + "   "
        + (.target // "")
        + (if .summary != null and .summary != "" then "    | " + .summary else "" end)
      )
  ' 2>/dev/null)

  if [ -z "$_lines" ]; then
    printf '(no recent tool calls)'
    return 0
  fi

  # Redact via the shared chain from transcript.sh.
  if command -v _pp_tx_redact >/dev/null 2>&1; then
    printf '%s' "$_lines" | _pp_tx_redact
  else
    # Last-resort: print verbatim. _pp_tx_redact should always be
    # available when this lib is loaded, but defensive.
    printf '%s' "$_lines"
  fi
}
