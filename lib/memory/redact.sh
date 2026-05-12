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
  LC_ALL=C printf '%s' "$body" \
    | LC_ALL=C sed -E '
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
