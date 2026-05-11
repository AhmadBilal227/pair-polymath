#!/usr/bin/env bash
# PostToolUse hook: captures test/lint Bash command results into a per-session cache
# so the polymath advisor can flag real test failures.

set -u

input=$(cat 2>/dev/null || echo '{}')
session_id=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ -z "$session_id" ] && exit 0
[ "$tool_name" != "Bash" ] && exit 0

command=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Match common test/lint patterns
case "$command" in
  *"npm test"*|*"pnpm test"*|*"yarn test"*|*"pytest"*|*"jest"*|*"vitest"*|\
  *"go test"*|*"cargo test"*|\
  *"npm run lint"*|*"pnpm lint"*|*"yarn lint"*|*"eslint"*|*"ruff"*|*"mypy"*|*"tsc "*|*"tsc"|\
  *"rspec"*|*"phpunit"*|*"dotnet test"*)
    cache="${HOME}/.claude/cache/cc-test-${session_id}.cache"
    mkdir -p "${HOME}/.claude/cache" 2>/dev/null
    is_error=$(echo "$input" | jq -r '.tool_response.is_error // false' 2>/dev/null)
    output=$(echo "$input" | jq -r '.tool_response.content // ""' 2>/dev/null | head -c 1500)
    cat > "$cache" <<DAT
TIMESTAMP: $(date +%s)
COMMAND: $command
ERROR: $is_error
OUTPUT (first 1500 chars):
$output
DAT
    ;;
esac
exit 0
