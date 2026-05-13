#!/usr/bin/env bats
# Tests for lib/transcript.sh — filtered conversation extractor.
# Hermetic: HOME under mktemp; no real ~/.claude touched.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR"
  export CLAUDE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  # shellcheck source=../lib/transcript.sh
  . "$PP_ROOT/lib/transcript.sh"
  FIX="$PP_ROOT/test/fixtures/transcript"
}

teardown() {
  rm -rf "$HOME"
}

# ----- pp_transcript_filter -----

@test "filter: empty file returns empty string" {
  run pp_transcript_filter "$FIX/session-empty.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "filter: non-existent file returns 0 with empty output" {
  run pp_transcript_filter "/no/such/file.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "filter: keeps user STRING content as USER: line" {
  run pp_transcript_filter "$FIX/session-mixed.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'USER: ship the auth refactor'
}

@test "filter: keeps user ARRAY-of-text content as USER: line (Critical #3)" {
  run pp_transcript_filter "$FIX/session-mixed.jsonl"
  [ "$status" -eq 0 ]
  # "also add JWT rotation" is in {type:"text"} inside content array
  echo "$output" | grep -qF 'USER: also add JWT rotation'
}

@test "filter: skips user-role tool_result wrapper (not a user message)" {
  run pp_transcript_filter "$FIX/session-mixed.jsonl"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'tool_result'
  ! echo "$output" | grep -qF '300 lines elided'
}

@test "filter: keeps assistant text blocks as CLAUDE: line" {
  run pp_transcript_filter "$FIX/session-mixed.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'CLAUDE: I will split authenticate'
}

@test "filter: keeps thinking when PP_TRANSCRIPT_KEEP_THINKING=1 (default)" {
  PP_TRANSCRIPT_KEEP_THINKING=1 run pp_transcript_filter "$FIX/session-mixed.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'thinking'
  echo "$output" | grep -qF 'User wants auth refactor'
}

@test "filter: drops thinking when PP_TRANSCRIPT_KEEP_THINKING=0" {
  PP_TRANSCRIPT_KEEP_THINKING=0 run pp_transcript_filter "$FIX/session-mixed.jsonl"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'thinking'
}

@test "filter: drops tool_use blocks from text path" {
  run pp_transcript_filter "$FIX/session-mixed.jsonl"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'tool_use'
}

@test "filter: redacts OpenAI sk- key in user content (Critical #1)" {
  run pp_transcript_filter "$FIX/session-with-secrets.jsonl"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'sk-proj-abcdef1234'
  echo "$output" | grep -qF 'REDACTED'
}

@test "filter: redacts AWS AKIA key in assistant text" {
  run pp_transcript_filter "$FIX/session-with-secrets.jsonl"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'AKIAIOSFODNN7EXAMPLE'
}

@test "filter: redacts GitHub ghp_ token in user content" {
  run pp_transcript_filter "$FIX/session-with-secrets.jsonl"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789AB'
}

@test "filter: tail-clips to PP_TRANSCRIPT_MAX bytes" {
  big="$(mktemp)"
  i=0
  while [ "$i" -lt 500 ]; do
    printf '{"type":"user","message":{"role":"user","content":"msg %d"}}\n' "$i" >> "$big"
    i=$((i + 1))
  done
  PP_TRANSCRIPT_MAX=512 run pp_transcript_filter "$big"
  [ "$status" -eq 0 ]
  out_bytes=$(printf '%s' "$output" | wc -c | tr -d ' ')
  [ "$out_bytes" -le 512 ]
  echo "$output" | grep -qF 'msg 499'
  rm -f "$big"
}

@test "filter: survives malformed JSON lines (drops them silently)" {
  bad="$(mktemp)"
  printf '{"type":"user","message":{"role":"user","content":"good"}}\n' > "$bad"
  printf 'not-json garbage\n' >> "$bad"
  printf '{"type":"user","message":{"role":"user","content":"also good"}}\n' >> "$bad"
  run pp_transcript_filter "$bad"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'USER: good'
  echo "$output" | grep -qF 'USER: also good'
  rm -f "$bad"
}

# ----- pp_transcript_tool_calls -----

@test "tool_calls: empty file returns []" {
  run pp_transcript_tool_calls "$FIX/session-empty.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "tool_calls: non-existent file returns []" {
  run pp_transcript_tool_calls "/no/such/file.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "tool_calls: extracts tool_use with paired result by id" {
  run pp_transcript_tool_calls "$FIX/session-mixed.jsonl"
  [ "$status" -eq 0 ]
  # Should have toolu_001 → Read /repo/auth.ts
  echo "$output" | jq -e '.[] | select(.id == "toolu_001") | .tool == "Read"' >/dev/null
  echo "$output" | jq -e '.[] | select(.id == "toolu_001") | .target == "/repo/auth.ts"' >/dev/null
  echo "$output" | jq -e '.[] | select(.id == "toolu_001") | .summary | contains("authenticate")' >/dev/null
}

@test "tool_calls: interleaved use/use/result/result paired by ID (Critical #2)" {
  run pp_transcript_tool_calls "$FIX/session-interleaved.jsonl"
  [ "$status" -eq 0 ]
  # Two tool calls with separate ids
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 2 ]
  # toolu_A → contents of A; toolu_B → contents of B (NOT crossed)
  echo "$output" | jq -e '.[] | select(.id == "toolu_A") | .summary | contains("contents of A")' >/dev/null
  echo "$output" | jq -e '.[] | select(.id == "toolu_B") | .summary | contains("contents of B")' >/dev/null
  # And NOT cross-matched
  ! echo "$output" | jq -e '.[] | select(.id == "toolu_A") | .summary | contains("contents of B")' >/dev/null
}

@test "tool_calls: caps at PP_TOOL_SUMMARY_MAX (newest kept)" {
  big="$(mktemp)"
  i=0
  while [ "$i" -lt 30 ]; do
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_%d","name":"Read","input":{"file_path":"/f/%d"}}]}}\n' "$i" "$i" >> "$big"
    i=$((i + 1))
  done
  PP_TOOL_SUMMARY_MAX=5 run pp_transcript_tool_calls "$big"
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 5 ]
  # Newest is tu_29
  echo "$output" | jq -e 'last.id == "tu_29"' >/dev/null
  rm -f "$big"
}

@test "tool_calls: truncates target longer than PP_TRANSCRIPT_TOOL_TRUNC (Important #5)" {
  long_path=$(printf 'a%.0s' $(seq 1 600))
  tmp="$(mktemp)"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_long","name":"Read","input":{"file_path":"/path/%s"}}]}}\n' "$long_path" > "$tmp"
  PP_TRANSCRIPT_TOOL_TRUNC=100 run pp_transcript_tool_calls "$tmp"
  [ "$status" -eq 0 ]
  target_len=$(echo "$output" | jq -r '.[0].target | length')
  [ "$target_len" -le 110 ]
  echo "$output" | jq -e '.[0].target | endswith("...")' >/dev/null
  rm -f "$tmp"
}

@test "tool_calls: tool_use without result has null summary" {
  tmp="$(mktemp)"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_solo","name":"Bash","input":{"command":"ls"}}]}}\n' > "$tmp"
  run pp_transcript_tool_calls "$tmp"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].summary == null' >/dev/null
  echo "$output" | jq -e '.[0].tool == "Bash"' >/dev/null
  echo "$output" | jq -e '.[0].target == "ls"' >/dev/null
  rm -f "$tmp"
}

@test "tool_calls: handles Bash / Edit / Write / Grep / WebFetch tool kinds" {
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"echo hi"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b","name":"Edit","input":{"file_path":"/x.ts"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"c","name":"Write","input":{"file_path":"/y.ts"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"d","name":"Grep","input":{"pattern":"foo"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"e","name":"WebFetch","input":{"url":"https://example.com"}}]}}
EOF
  run pp_transcript_tool_calls "$tmp"
  [ "$status" -eq 0 ]
  for tool in Bash Edit Write Grep WebFetch; do
    echo "$output" | jq -e --arg t "$tool" '.[] | select(.tool == $t)' >/dev/null
  done
  rm -f "$tmp"
}
