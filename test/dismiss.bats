#!/usr/bin/env bats
# v0.5 Phase 3 — dismiss subsystem.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR/dismiss"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  # shellcheck source=../lib/memory/schema.sh
  . "$PP_ROOT/lib/memory/schema.sh"
  # shellcheck source=../lib/dismiss.sh
  . "$PP_ROOT/lib/dismiss.sh"
}

teardown() { rm -rf "$HOME"; }

@test "dismiss_add: appends one JSONL line with the expected fields" {
  pp_dismiss_add "Browser-side API keys are intentional" project
  local _file
  _file=$(pp_dismiss_file_path)
  [ -f "$_file" ]
  [ "$(wc -l < "$_file" | tr -d ' ')" = "1" ]
  jq -e '.id and .ts and .reason_summary and .scope == "project" and .source == "manual" and .deleted == false' "$_file" >/dev/null
}

@test "dismiss_list: empty list prints zero lines and exits 0" {
  run pp_dismiss_list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dismiss_list: returns active rules only (deleted excluded)" {
  pp_dismiss_add "Rule A" project
  pp_dismiss_add "Rule B" project
  local _file _id_b
  _file=$(pp_dismiss_file_path)
  _id_b=$(jq -r 'select(.reason_summary == "Rule B") | .id' "$_file" | head -1)
  local _tmp
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id_b\" then .deleted = true else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  run pp_dismiss_list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "Rule A"
  ! printf '%s' "$output" | grep -qF "Rule B"
}

@test "dismiss_list: TTL-expired rules are excluded" {
  pp_dismiss_add "Old expired rule" project
  local _file _id
  _file=$(pp_dismiss_file_path)
  _id=$(jq -r '.id' "$_file" | head -1)
  local _backdate _tmp
  _backdate=$(date -u -v -10d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id\" then .ts = \"$_backdate\" | .ttl_days = 5 else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  run pp_dismiss_list
  [ "$status" -eq 0 ]
  ! printf '%s' "$output" | grep -qF "Old expired rule"
}

@test "dismiss_list: TTL-not-yet-expired rules ARE included" {
  pp_dismiss_add "Fresh rule with ttl" project
  local _file _id _tmp
  _file=$(pp_dismiss_file_path)
  _id=$(jq -r '.id' "$_file" | head -1)
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id\" then .ttl_days = 30 else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  run pp_dismiss_list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "Fresh rule with ttl"
}

@test "dismiss_show: prints full JSON record for a given id" {
  local _id
  _id=$(pp_dismiss_add "Showable rule" project)
  run pp_dismiss_show "$_id"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.id == "'"$_id"'"' >/dev/null
}

@test "dismiss_show: unknown id exits non-zero with diagnostic to stderr" {
  run pp_dismiss_show "d-does-not-exist"
  [ "$status" -ne 0 ]
}

@test "dismiss_disable: flips deleted=true and records deleted_reason" {
  local _id
  _id=$(pp_dismiss_add "Disable me" project)
  run pp_dismiss_disable "$_id" "user_disabled"
  [ "$status" -eq 0 ]
  run pp_dismiss_show "$_id"
  printf '%s' "$output" | jq -e '.deleted == true and .deleted_reason == "user_disabled"' >/dev/null
}

@test "dismiss_enable: flips deleted=false on a previously-disabled rule" {
  local _id
  _id=$(pp_dismiss_add "Toggle me" project)
  pp_dismiss_disable "$_id" "user_disabled"
  run pp_dismiss_enable "$_id"
  [ "$status" -eq 0 ]
  run pp_dismiss_show "$_id"
  printf '%s' "$output" | jq -e '.deleted == false' >/dev/null
}

@test "dismiss_render: empty file produces empty stdout" {
  run pp_dismiss_render
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dismiss_render: emits bullet list with one bullet per active rule" {
  pp_dismiss_add "Rule one" project
  pp_dismiss_add "Rule two" project
  run pp_dismiss_render
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qE '^- Rule one'
  printf '%s' "$output" | grep -qE '^- Rule two'
  [ "$(printf '%s\n' "$output" | grep -cE '^- ')" = "2" ]
}

@test "dismiss_render: dedups by exact reason_summary match" {
  pp_dismiss_add "Same constraint" project
  pp_dismiss_add "Same constraint" project
  run pp_dismiss_render
  [ "$(printf '%s\n' "$output" | grep -cE '^- Same constraint')" = "1" ]
}

@test "dismiss_render: caps total output at PP_DISMISS_RENDERED_MAX_BYTES" {
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    pp_dismiss_add "Rule number $_i with verbose padding text to consume bytes" project
  done
  PP_DISMISS_RENDERED_MAX_BYTES=200 run pp_dismiss_render
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | wc -c | tr -d ' ')" -le 200 ]
}

@test "dismiss_render: cache invalidates only when source JSONL mtime is newer" {
  pp_dismiss_add "Rule for cache test" project
  local _out1 _out2
  _out1=$(pp_dismiss_render)
  _out2=$(pp_dismiss_render)
  [ "$_out1" = "$_out2" ]
  [ -f "$PP_CACHE_DIR/cc-dismiss-rendered-$(pp_memory_project_hash "$PWD").txt" ]
}

@test "is_suppressed: returns 0 (suppressed) when hash matches an active rule" {
  local _id _file _tmp
  _id=$(pp_dismiss_add "Hash-tagged rule" project)
  _file=$(pp_dismiss_file_path)
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id\" then .hash = \"abc123\" else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  run pp_dismiss_is_suppressed "abc123"
  [ "$status" -eq 0 ]
}

@test "is_suppressed: returns 1 (not suppressed) when no rule matches" {
  pp_dismiss_add "Some rule" project
  run pp_dismiss_is_suppressed "no-such-hash"
  [ "$status" -ne 0 ]
}

@test "is_suppressed: returns 1 when rule's hash matches but rule is deleted" {
  local _id _file _tmp
  _id=$(pp_dismiss_add "Will be disabled" project)
  pp_dismiss_disable "$_id" user_disabled
  _file=$(pp_dismiss_file_path)
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id\" then .hash = \"def456\" else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  run pp_dismiss_is_suppressed "def456"
  [ "$status" -ne 0 ]
}
