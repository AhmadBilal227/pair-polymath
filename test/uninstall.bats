#!/usr/bin/env bats
# Uninstaller regression tests.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  export CLAUDE_DIR
  mkdir -p "$CLAUDE_DIR"
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}

teardown() {
  rm -rf "$HOME"
}

@test "uninstall removes statusline and all Pair Polymath hooks including SessionEnd" {
  cat > "$CLAUDE_DIR/settings.json" <<'JSON'
{
  "statusLine": {"type": "command", "command": "bash /old/path/statusline.sh", "refreshInterval": 2},
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "/old/path/inject-monitor-insight.sh", "timeout": 3},
        {"type": "command", "command": "/keep/user-hook.sh", "timeout": 3}
      ]}
    ],
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "/old/path/cache-test-result.sh", "timeout": 3},
        {"type": "command", "command": "/keep/post-hook.sh", "timeout": 3}
      ]}
    ],
    "SessionEnd": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "/old/path/session-end.sh", "timeout": 3},
        {"type": "command", "command": "/keep/session-hook.sh", "timeout": 3}
      ]}
    ]
  }
}
JSON

  run bash "$PP_ROOT/bin/uninstall.sh"
  [ "$status" -eq 0 ]

  jq -e 'has("statusLine") | not' "$CLAUDE_DIR/settings.json" >/dev/null
  jq -e '[.hooks.UserPromptSubmit[]?.hooks[]?.command | select(test("inject-monitor-insight\\.sh"))] | length == 0' "$CLAUDE_DIR/settings.json" >/dev/null
  jq -e '[.hooks.PostToolUse[]?.hooks[]?.command | select(test("cache-test-result\\.sh"))] | length == 0' "$CLAUDE_DIR/settings.json" >/dev/null
  jq -e '[.hooks.SessionEnd[]?.hooks[]?.command | select(test("session-end\\.sh"))] | length == 0' "$CLAUDE_DIR/settings.json" >/dev/null

  jq -e '[.hooks.UserPromptSubmit[]?.hooks[]?.command | select(. == "/keep/user-hook.sh")] | length == 1' "$CLAUDE_DIR/settings.json" >/dev/null
  jq -e '[.hooks.PostToolUse[]?.hooks[]?.command | select(. == "/keep/post-hook.sh")] | length == 1' "$CLAUDE_DIR/settings.json" >/dev/null
  jq -e '[.hooks.SessionEnd[]?.hooks[]?.command | select(. == "/keep/session-hook.sh")] | length == 1' "$CLAUDE_DIR/settings.json" >/dev/null
}
