#!/usr/bin/env bash
# lib/transcript.sh — filtered conversation extractor for analyst context.
#
# Owns: the transformation from a raw Claude Code JSONL transcript into a
# compact "what humans said + what Claude said + what Claude thought"
# stream, plus a structured tool-call array. Drops tool inputs and
# outputs from the text stream — they're huge, and the tool-call array
# captures the same signal with bounded cost. Runs the redactor over the
# final filtered text so secrets in user/Claude content can't reach the
# LLM call.
#
# Public functions:
#   pp_transcript_filter <path>       → stdout: filtered text
#   pp_transcript_tool_calls <path>   → stdout: JSON array of tool calls
#
# Env vars (override via shell or config/default.env):
#   PP_TRANSCRIPT_MAX               (16384) Output cap, tail-biased
#   PP_TRANSCRIPT_USER_TRUNC        (2048)  Per-user-message cap
#   PP_TRANSCRIPT_ASSISTANT_TRUNC   (4096)  Per-assistant-text cap
#   PP_TRANSCRIPT_KEEP_THINKING     (1)     1=keep, 0=drop
#   PP_TRANSCRIPT_TOOL_TRUNC        (512)   Truncate tool target/summary
#   PP_TOOL_SUMMARY_MAX             (20)   Max tool calls retained
#
# Bash 3.2-portable. Uses jq for parsing. Silently no-ops on missing
# file. Malformed JSON lines are skipped (per-line try/catch in jq).
# No global LC_ALL=C (intentional — jq is locale-independent and awk
# operations here are string-only; locale handling is the caller's
# responsibility).

if [ -n "${_PP_TRANSCRIPT_SOURCED:-}" ]; then return 0; fi
_PP_TRANSCRIPT_SOURCED=1

: "${PP_TRANSCRIPT_MAX:=16384}"
: "${PP_TRANSCRIPT_USER_TRUNC:=2048}"
: "${PP_TRANSCRIPT_ASSISTANT_TRUNC:=4096}"
: "${PP_TRANSCRIPT_KEEP_THINKING:=1}"
: "${PP_TRANSCRIPT_TOOL_TRUNC:=512}"
: "${PP_TOOL_SUMMARY_MAX:=20}"

# Source the project's canonical redactor (lib/memory/redact.sh defines
# pp_memory_redact_body, which covers 11 secret patterns including
# URI-creds, Bearer, Stripe, Slack, JWT, DB-URIs, .env paths).
# This is the IMPORTANT review fix from GPT plan-review round 2 / AI-eng
# C1: the function name `pp_redact_secrets` (which earlier draft assumed)
# does NOT exist in the codebase — only pp_memory_redact_body does.
# Without this source, the fallback below runs 100% of cycles and leaks
# 7 secret classes. Sourcing redact.sh is cheap (one-shot at load) and
# the source-guard inside redact.sh makes re-sourcing a no-op.
_pp_tx_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${_PP_GROUNDING_SOURCED:-}" ] && [ -r "${_pp_tx_self_dir}/grounding.sh" ]; then
  # shellcheck source=grounding.sh
  . "${_pp_tx_self_dir}/grounding.sh" 2>/dev/null || true
fi
if ! command -v pp_memory_redact_body >/dev/null 2>&1; then
  if [ -r "${_pp_tx_self_dir}/memory/redact.sh" ]; then
    # shellcheck source=memory/redact.sh
    . "${_pp_tx_self_dir}/memory/redact.sh" 2>/dev/null || true
  fi
fi

# Built-in fallback redactor. awk-based for BusyBox/Alpine compatibility
# (no sed -E). Handles 4 canonical key shapes; the project's
# lib/memory/redact.sh has the 11-pattern comprehensive list — this is
# the safety net when redact.sh failed to source.
_pp_tx_redact_fallback() {
  awk '
    {
      line = $0
      while (match(line, /sk-[A-Za-z0-9_-]{20,}/)) {
        line = substr(line, 1, RSTART-1) "[REDACTED-OPENAI]" substr(line, RSTART+RLENGTH)
      }
      while (match(line, /AKIA[0-9A-Z]{16}/)) {
        line = substr(line, 1, RSTART-1) "[REDACTED-AWS]" substr(line, RSTART+RLENGTH)
      }
      while (match(line, /(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}/)) {
        line = substr(line, 1, RSTART-1) "[REDACTED-GH]" substr(line, RSTART+RLENGTH)
      }
      while (match(line, /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/)) {
        line = substr(line, 1, RSTART-1) "[REDACTED-JWT]" substr(line, RSTART+RLENGTH)
      }
      print line
    }
  '
}

# Dispatch: prefer the project's canonical pp_memory_redact_body (11
# patterns), fall back to the 4-pattern awk built-in. pp_memory_redact_body
# takes a BODY argument and writes redacted output to stdout — the
# wrapper here adapts stdin → arg so callers can pipe in.
_pp_tx_redact() {
  local _body
  _body=$(cat)
  if command -v pp_memory_redact_body >/dev/null 2>&1; then
    pp_memory_redact_body "$_body"
  else
    printf '%s' "$_body" | _pp_tx_redact_fallback
  fi
}

# pp_transcript_filter <path>
# Stdout: filtered conversation, one event per line, tail-biased,
# redacted. Empty output for missing/empty/unreadable input.
pp_transcript_filter() {
  local _path="${1:-}"
  if [ -z "$_path" ] || [ ! -r "$_path" ]; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  # Tail by bytes BEFORE handing to jq — protects against multi-MB
  # transcripts. 4x cap gives generous headroom; partial leading line
  # fails parse and is dropped per-line.
  local _max_input=$((PP_TRANSCRIPT_MAX * 4))
  local _tailed
  _tailed=$(tail -c "$_max_input" "$_path" 2>/dev/null) || return 0
  if [ -z "$_tailed" ]; then
    return 0
  fi

  local _keep_think="${PP_TRANSCRIPT_KEEP_THINKING}"
  local _user_cap="${PP_TRANSCRIPT_USER_TRUNC}"
  local _ast_cap="${PP_TRANSCRIPT_ASSISTANT_TRUNC}"

  # jq program. -R: raw line. fromjson per-line tolerantly (try/catch).
  # User content can be:
  #   - string: bare user message → emit USER:
  #   - array of {type:"text"}: also a user message → emit USER:
  #   - array of {type:"tool_result"}: a tool result wrapper → skip
  # Assistant content is always array; walk for text and (optionally) thinking.
  local _jq_prog
  _jq_prog='
    def trunc($n): if (. | length) > $n then (.[0:$n] + "...[truncated]") else . end;
    . as $raw
    | (try ($raw | fromjson) catch null) as $rec
    | select($rec != null)
    | if $rec.type == "user" then
        ($rec.message.content // null) as $c
        | if ($c | type) == "string" then
            "USER: " + ($c | trunc('"$_user_cap"'))
          elif ($c | type) == "array" then
            ($c | map(select(.type == "text") | .text // "") | join(" ")) as $joined
            | if ($joined | length) > 0 then
                "USER: " + ($joined | trunc('"$_user_cap"'))
              else empty end
          else empty end
      elif $rec.type == "assistant" then
        ($rec.message.content // []) as $arr
        | $arr[]
        | if .type == "text" then
            "CLAUDE: " + ((.text // "") | trunc('"$_ast_cap"'))
          elif .type == "thinking" and '"$_keep_think"' == 1 then
            "CLAUDE(thinking): " + ((.text // "") | trunc('"$_ast_cap"'))
          else empty end
      else empty end
  '

  local _full
  _full=$(printf '%s' "$_tailed" | jq -Rr "$_jq_prog" 2>/dev/null)
  if [ -z "$_full" ]; then
    return 0
  fi

  # Tail-clip to PP_TRANSCRIPT_MAX bytes, then redact.
  # tail -c is byte-accurate on macOS + GNU; multi-byte split is
  # documented as acceptable (LLM tokenizer tolerates partial UTF-8).
  printf '%s\n' "$_full" | tail -c "$PP_TRANSCRIPT_MAX" | _pp_tx_redact
}

# pp_transcript_tool_calls <path>
# Stdout: JSON array of tool invocations, newest-at-end.
# Each element: {tool, id, target, summary}.
# Pairs tool_use → tool_result via tool_use.id ↔ tool_result.tool_use_id
# (NOT by adjacency — adjacency misattributes when interleaved).
# Bounded by PP_TOOL_SUMMARY_MAX.
pp_transcript_tool_calls() {
  local _path="${1:-}"
  if [ -z "$_path" ] || [ ! -r "$_path" ]; then
    printf '[]'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '[]'
    return 0
  fi

  local _max_input=$((PP_TRANSCRIPT_MAX * 4))
  local _tailed
  _tailed=$(tail -c "$_max_input" "$_path" 2>/dev/null) || { printf '[]'; return 0; }
  if [ -z "$_tailed" ]; then
    printf '[]'
    return 0
  fi

  local _tool_trunc="${PP_TRANSCRIPT_TOOL_TRUNC}"
  local _max_tools="${PP_TOOL_SUMMARY_MAX}"

  local _result
  _result=$(printf '%s' "$_tailed" | jq -Rs \
    --argjson trunc "$_tool_trunc" \
    --argjson max "$_max_tools" \
    '
    split("\n")
    | map(select(length > 0) | (try fromjson catch null))
    | map(select(. != null))
    | [ .[]
        | select(.type == "assistant" or .type == "user")
        | .message.content as $c
        | if ($c | type) == "array" then
            $c[] | select(.type == "tool_use" or .type == "tool_result")
          else empty end
      ] as $events
    | ( $events
        | map(select(.type == "tool_result" and (.tool_use_id // "") != ""))
        | map({key: .tool_use_id, value: .})
        | from_entries
      ) as $results_by_id
    | ( $events
        | map(select(.type == "tool_use"))
        | map(
            . as $u
            | (if ($u.id // "") != "" then $results_by_id[$u.id] else null end) as $r
            | {
                tool:   ($u.name // "?"),
                id:     ($u.id // null),
                target: (
                  ($u.input.file_path // $u.input.command // $u.input.pattern // $u.input.url // "")
                  | tostring
                  | if length > $trunc then .[0:$trunc] + "..." else . end
                ),
                summary: (
                  if $r != null then
                    (($r.content // []) | map(select(.type == "text") | .text // "") | join(" "))
                    | if length > $trunc then .[0:$trunc] + "..." else . end
                  else null end
                )
              }
          )
      )
    | if length <= $max then . else .[length - $max:] end
  ' 2>/dev/null)

  if [ -z "$_result" ] || [ "$_result" = "null" ]; then
    printf '[]'
  else
    printf '%s' "$_result"
  fi
}
