#!/usr/bin/env bats
# Tests for lib/tool-summary.sh — JSON → text renderer with redaction.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  # shellcheck source=../lib/tool-summary.sh
  . "$PP_ROOT/lib/tool-summary.sh"
}

teardown() { rm -rf "$HOME"; }

@test "render: empty array → '(no recent tool calls)'" {
  run pp_tool_summary_render '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "(no recent tool calls)" ]
}

@test "render: empty string → '(no recent tool calls)'" {
  run pp_tool_summary_render ''
  [ "$status" -eq 0 ]
  [ "$output" = "(no recent tool calls)" ]
}

@test "render: malformed JSON → '(no recent tool calls)' (Minor #13)" {
  run pp_tool_summary_render 'not json at all'
  [ "$status" -eq 0 ]
  [ "$output" = "(no recent tool calls)" ]
}

@test "render: non-array JSON → '(no recent tool calls)'" {
  run pp_tool_summary_render '{"oops":"object not array"}'
  [ "$status" -eq 0 ]
  [ "$output" = "(no recent tool calls)" ]
}

@test "render: Read call shows tool name + target + summary" {
  json='[{"tool":"Read","id":"a","target":"/repo/auth.ts","summary":"export function authenticate"}]'
  run pp_tool_summary_render "$json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'Read'
  echo "$output" | grep -qF '/repo/auth.ts'
  echo "$output" | grep -qF 'export function authenticate'
}

@test "render: Bash call shows command + summary" {
  json='[{"tool":"Bash","id":"a","target":"pnpm test","summary":"3 passing, 1 failing: auth.test.ts"}]'
  run pp_tool_summary_render "$json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'pnpm test'
  echo "$output" | grep -qF '1 failing: auth.test.ts'
}

@test "render: tool_use without summary omits the | separator" {
  json='[{"tool":"Bash","id":"a","target":"ls","summary":null}]'
  run pp_tool_summary_render "$json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'ls'
  ! echo "$output" | grep -qF '|'
}

@test "render: multiple calls each on own line" {
  json='[{"tool":"Read","id":"a","target":"/a","summary":null},{"tool":"Bash","id":"b","target":"ls","summary":null}]'
  run pp_tool_summary_render "$json"
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  [ "$line_count" -eq 2 ]
}

@test "render: redacts OpenAI sk- key in summary (Critical #1 propagation)" {
  json='[{"tool":"Bash","id":"a","target":"echo redacted","summary":"detected sk-proj-abcdef1234567890abcdef1234567890ABCDEF in env"}]'
  run pp_tool_summary_render "$json"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'sk-proj-abcdef1234'
  echo "$output" | grep -qF 'REDACTED'
}

@test "render: redacts AWS key in target field" {
  json='[{"tool":"Bash","id":"a","target":"echo AKIAIOSFODNN7EXAMPLE","summary":null}]'
  run pp_tool_summary_render "$json"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'AKIAIOSFODNN7EXAMPLE'
}

@test "render: redacts GitHub token in summary" {
  json='[{"tool":"Bash","id":"a","target":"x","summary":"ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789AB found in commit"}]'
  run pp_tool_summary_render "$json"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ'
}

@test "render: all common tool kinds (Bash/Edit/Write/Read/Grep/WebFetch)" {
  json='[
    {"tool":"Read","id":"a","target":"/a","summary":null},
    {"tool":"Edit","id":"b","target":"/b","summary":null},
    {"tool":"Write","id":"c","target":"/c","summary":null},
    {"tool":"Bash","id":"d","target":"x","summary":null},
    {"tool":"Grep","id":"e","target":"pat","summary":null},
    {"tool":"WebFet","id":"f","target":"http","summary":null}
  ]'
  run pp_tool_summary_render "$json"
  [ "$status" -eq 0 ]
  for t in Read Edit Write Bash Grep WebFet; do
    echo "$output" | grep -qF "$t"
  done
}
