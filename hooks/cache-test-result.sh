#!/usr/bin/env bash
# PostToolUse hook: captures test/lint Bash command results into a per-session cache
# so the polymath advisor can flag real test failures.

set -u
umask 077

input=$(cat 2>/dev/null || echo '{}')
session_id=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ -z "$session_id" ] && exit 0
[ "$tool_name" != "Bash" ] && exit 0

PP_ROOT="${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/config.sh" 2>/dev/null || true
PP_CACHE_DIR="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
session_id=$(pp_sanitize_session_id "$session_id")

command=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Match common test/lint patterns
case "$command" in
  *"npm test"*|*"pnpm test"*|*"yarn test"*|*"pytest"*|*"jest"*|*"vitest"*|\
  *"go test"*|*"cargo test"*|\
  *"npm run lint"*|*"pnpm lint"*|*"yarn lint"*|*"eslint"*|*"ruff"*|*"mypy"*|*"tsc "*|*"tsc"|\
  *"rspec"*|*"phpunit"*|*"dotnet test"*)
    cache="${PP_CACHE_DIR}/cc-test-${session_id}.cache"
    mkdir -p "$PP_CACHE_DIR" 2>/dev/null
    chmod 700 "$PP_CACHE_DIR" 2>/dev/null || true
    is_error=$(echo "$input" | jq -r '.tool_response.is_error // false' 2>/dev/null)
    # Keep the failure TAIL (where errors surface) rather than the banner head.
    output=$(echo "$input" | jq -r '.tool_response.content // ""' 2>/dev/null | tail -c 1500)
    tmp=$(mktemp "${cache}.XXXXXX" 2>/dev/null) || exit 0
    {
      printf 'TIMESTAMP: %s\n' "$(date +%s)"
      printf 'COMMAND: %s\n' "$command"
      printf 'ERROR: %s\n' "$is_error"
      printf 'OUTPUT (last 1500 chars):\n%s\n' "$output"
    } > "$tmp" 2>/dev/null && mv "$tmp" "$cache" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
    ;;
esac
exit 0
