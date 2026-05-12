#!/usr/bin/env bash
# Pair Polymath — memory redaction defaults. Strips secret-shaped tokens
# and validates paths before persistence. Off-by-default sentinel patterns
# used to be in scope; this enforces them at the storage boundary.
#
# CONTRACT: This file sources lib/grounding.sh on load so pp_contain_path
# is available. Callers do NOT need to pre-source grounding.sh.

# Resolve PP_ROOT relative to this file if not set, so the source-in works
# whether the caller has exported PP_ROOT or not.
if [ -z "${PP_ROOT:-}" ]; then
  _pp_memory_redact_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
  PP_ROOT="$_pp_memory_redact_dir"
  unset _pp_memory_redact_dir
fi
# shellcheck disable=SC1091
. "$PP_ROOT/lib/grounding.sh"

pp_memory_redact_body() {
  local body="$1"
  # R3.7 — URI userpass redaction (`scheme://user:pass@host`) MUST run before
  # email so the `:` and `@` in `user:pass@host.com` aren't matched as email.
  # Covers https/http/ssh/ftp/etc. and the DB-URI shape simultaneously.
  LC_ALL=C printf '%s' "$body" \
    | LC_ALL=C sed -E '
        s|([a-zA-Z][a-zA-Z0-9+.-]*)://[^[:space:]:/?#@]+:[^[:space:]@]+@|\1://[REDACTED-USERPASS]@|g
        s|sk-[A-Za-z0-9_-]{20,}|[REDACTED-OPENAI]|g
        s|Bearer [A-Za-z0-9._-]{20,}|[REDACTED-BEARER]|g
        s|ghp_[A-Za-z0-9]{20,}|[REDACTED-GHP]|g
        s|github_pat_[A-Za-z0-9_]{20,}|[REDACTED-GHPAT]|g
        s|AKIA[A-Z0-9]{16}|[REDACTED-AWS]|g
        s|xox[abprs]-[A-Za-z0-9-]{20,}|[REDACTED-SLACK]|g
        s|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|[REDACTED-EMAIL]|g
        s|(pk\|sk\|rk)_(live\|test)_[A-Za-z0-9]{20,}|[REDACTED-STRIPE]|g
        s|eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|[REDACTED-JWT]|g
        s|(postgres(ql)?\|mysql\|mongodb(\+srv)?\|redis\|amqp)://[^[:space:]'\''"]+|[REDACTED-DBURI]|g
        s|(^\|[[:space:]/'\''"=])(\.env(\.[a-zA-Z0-9_-]+)?)([[:space:]:'\''"]\|$)|\1[REDACTED-DOTENV]\4|g
      '
}

# pp_memory_sanitize_title TITLE
# R3.3 — defangs eviction-summary / pattern-extraction `title` fields before
# they land in patterns.jsonl PERMANENTLY. Titles get re-injected into every
# future analyst prompt, so a single LLM-generated string can pivot into a
# long-lived prompt injection unless validated here.
#
# Returns 0 + sanitized title on stdout when accepted.
# Returns 1 + empty stdout when rejected (caller must skip persisting).
#
# Acceptance rules:
#   - Length 10-200 chars (the prompt spec says 50-120 for normal cases and
#     defines a 47-char sentinel; loose bounds tolerate both while rejecting
#     pathological lengths)
#   - Strip ASCII control chars (newline, tab, NUL, etc.)
#   - Reject if contains role-override / instruction-override substrings
#     (case-insensitive): "system:", "assistant:", "user:" (when not part of
#     "user-..."), "ignore prior", "ignore previous", "ignore all instructions",
#     "you are now", "<|im_start|>", "<|im_end|>", "</s><s>"
#   - Run through pp_memory_redact_body to strip embedded secrets
pp_memory_sanitize_title() {
  local title="$1"
  # Strip CR/LF/TAB/NUL/other control chars.
  title=$(LC_ALL=C printf '%s' "$title" | LC_ALL=C tr -d '[:cntrl:]')
  # Reject empty after control-char strip.
  [ -z "$title" ] && return 1
  # Length bounds. byte count is fine — multibyte UTF-8 titles will measure
  # longer but the 200-char ceiling is generous.
  local len=${#title}
  [ "$len" -lt 10 ] && return 1
  if [ "$len" -gt 200 ]; then
    # Truncate to 200. Don't reject — preserve the leading content.
    title=$(LC_ALL=C printf '%s' "$title" | LC_ALL=C cut -c1-200)
  fi
  # Lowercase via tr (bash 3.2 portable; no ${var,,}).
  local lower
  lower=$(LC_ALL=C printf '%s' "$title" | LC_ALL=C tr 'A-Z' 'a-z')
  # Role-override / instruction-override patterns. case "$lower" in to avoid
  # the cost of repeated grep calls.
  case "$lower" in
    *system:*|*assistant:*) return 1 ;;
    *"ignore prior"*|*"ignore previous"*|*"ignore all instructions"*) return 1 ;;
    *"you are now"*) return 1 ;;
    *"<|im_start|>"*|*"<|im_end|>"*) return 1 ;;
    *"</s><s>"*) return 1 ;;
  esac
  # "user:" — only reject when it's actually a role marker, not a noun. Match
  # "user:" only at a word boundary (start, space, or punctuation before).
  case "$lower" in
    "user:"*|*' user:'*|*':user:'*) return 1 ;;
  esac
  # Pass through secret-pattern redaction. If a secret got embedded in the
  # title (e.g. "Bottom-50 evicted: most cite log line containing sk-abc..."),
  # this defangs it.
  pp_memory_redact_body "$title"
}

# pp_memory_redact_path PATH CWD
# Stdout: PATH if it's safely inside CWD; empty if outside (rejected).
# NOTE: under zsh, a `local path=` would shadow the special $path array
# that mirrors $PATH and break command resolution inside pp_contain_path
# (realpath etc.). Prefix with pp_ to avoid that collision.
pp_memory_redact_path() {
  local pp_path="$1"
  local pp_cwd="$2"
  # Use pp_contain_path from lib/grounding.sh (sourced on load).
  if pp_contain_path "$pp_cwd" "$pp_path" >/dev/null 2>&1; then
    printf '%s' "$pp_path"
  fi
}

# pp_memory_safe_path_shape PATH
# R3.9 — string-shape containment check (no filesystem access). Rejects:
#   - empty string
#   - leading `/` (absolute path escapes cwd)
#   - `..` anywhere (parent-dir traversal)
#   - leading `~` (tilde expansion downstream could leak)
#   - empty or `.` path components (a//b, a/./b normalize-ambiguous)
# Returns 0 + PATH on stdout if safe; 1 + empty on stdout if not.
#
# Use at storage time when realpath isn't viable (file may not exist YET,
# or may have been deleted between obs-emit and store-flush). Complements
# pp_memory_redact_path which uses realpath for filesystem-confirmed paths.
pp_memory_safe_path_shape() {
  local pp_path="$1"
  case "$pp_path" in
    ''|/*) return 1 ;;
    *..*)  return 1 ;;
    '~'*|*/'~'*) return 1 ;;
  esac
  if ! printf '%s' "$pp_path" | LC_ALL=C awk -F/ '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "" || $i == ".") { bad = 1; exit }
      }
    }
    END { exit (bad ? 1 : 0) }
  '; then
    return 1
  fi
  printf '%s' "$pp_path"
}
