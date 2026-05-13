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
