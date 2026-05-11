#!/usr/bin/env bats
# Path containment + grep safety from lib/grounding.sh.

setup() {
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../lib/grounding.sh"
  PP_TEST_BASE="$(mktemp -d)"
  mkdir -p "$PP_TEST_BASE/sub/nested"
  echo "ok" > "$PP_TEST_BASE/sub/file.txt"
  echo "ok" > "$PP_TEST_BASE/sub/nested/deep.txt"
  # macOS mktemp returns /var/... which realpath resolves to /private/var/...;
  # capture the resolved form for prefix-match assertions.
  PP_TEST_BASE_REAL="$(cd "$PP_TEST_BASE" && pwd -P)"
  # A sibling dir OUTSIDE the base, to test escape attempts
  PP_TEST_OUTSIDE="$(mktemp -d)"
  echo "secret" > "$PP_TEST_OUTSIDE/secret.txt"
}

teardown() {
  rm -rf "$PP_TEST_BASE" "$PP_TEST_OUTSIDE"
}

@test "contain: accepts a file inside base" {
  run pp_contain_path "$PP_TEST_BASE" "sub/file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == "$PP_TEST_BASE_REAL"/* ]]
}

@test "contain: accepts a deep file inside base" {
  run pp_contain_path "$PP_TEST_BASE" "sub/nested/deep.txt"
  [ "$status" -eq 0 ]
}

@test "contain: rejects ../ traversal escaping base" {
  run pp_contain_path "$PP_TEST_BASE" "../$(basename "$PP_TEST_OUTSIDE")/secret.txt"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: rejects absolute path outside base" {
  run pp_contain_path "$PP_TEST_BASE" "/etc/passwd"
  [ "$status" -ne 0 ]
}

@test "contain: rejects empty candidate" {
  run pp_contain_path "$PP_TEST_BASE" ""
  [ "$status" -ne 0 ]
}

@test "contain: rejects when base does not exist" {
  run pp_contain_path "/nonexistent/path" "anything"
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects empty pattern" {
  run pp_safe_grep_pattern ""
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects pure dot" {
  run pp_safe_grep_pattern "."
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects pure .*" {
  run pp_safe_grep_pattern ".*"
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects length 3" {
  run pp_safe_grep_pattern "abc"
  [ "$status" -ne 0 ]
}

@test "grep-safe: accepts reasonable identifier search" {
  run pp_safe_grep_pattern "TODO|FIXME"
  [ "$status" -eq 0 ]
}

@test "grep-safe: rejects > 100 char patterns" {
  local long
  long=$(printf 'a%.0s' $(seq 1 101))
  run pp_safe_grep_pattern "$long"
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects leading dash (option injection guard)" {
  run pp_safe_grep_pattern "-Roo"
  [ "$status" -ne 0 ]
  run pp_safe_grep_pattern "--include=foo"
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects alnum dwarfed by metachars" {
  # length>4 but only one alnum char — broad-match risk
  run pp_safe_grep_pattern "^.*a.*\$"
  [ "$status" -ne 0 ]
}

@test "grep-safe: accepts identifier with surrounding metachars" {
  # 3+ alnum chars present even with regex around them
  run pp_safe_grep_pattern "^budget_inc\\("
  [ "$status" -eq 0 ]
}
