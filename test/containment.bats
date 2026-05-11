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

# === pp_is_secret_file + integration with pp_contain_path ===

@test "secret-file: rejects basename matching .env" {
  run pp_is_secret_file "/some/path/.env"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects .env.local" {
  run pp_is_secret_file "/some/path/.env.local"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects production.env" {
  run pp_is_secret_file "/x/production.env"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects .envrc" {
  run pp_is_secret_file "/x/.envrc"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects *.pem / *.key / *.p12 / *.pfx" {
  for ext in pem key p12 pfx; do
    run pp_is_secret_file "/x/server.$ext"
    [ "$status" -eq 0 ]
  done
}

@test "secret-file: rejects credentials.json / secrets.yml" {
  run pp_is_secret_file "/x/credentials.json"
  [ "$status" -eq 0 ]
  run pp_is_secret_file "/x/secrets.yml"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects id_rsa / id_ed25519 / authinfo / .netrc" {
  for f in id_rsa id_rsa.pub id_ed25519 authinfo .netrc; do
    run pp_is_secret_file "/x/$f"
    [ "$status" -eq 0 ]
  done
}

@test "secret-file: rejects .npmrc / .pypirc" {
  run pp_is_secret_file "/x/.npmrc"
  [ "$status" -eq 0 ]
  run pp_is_secret_file "/x/.pypirc"
  [ "$status" -eq 0 ]
}

@test "secret-file: ACCEPTS regular source files" {
  for f in App.tsx main.py README.md package.json Makefile build.gradle; do
    run pp_is_secret_file "/x/$f"
    [ "$status" -ne 0 ]
  done
}

@test "secret-file: PP_SECRET_FILE_PATTERNS_EXTRA adds patterns additively" {
  PP_SECRET_FILE_PATTERNS_EXTRA="*.myorg-secret" run pp_is_secret_file "/x/foo.myorg-secret"
  [ "$status" -eq 0 ]
  # Defaults still apply
  PP_SECRET_FILE_PATTERNS_EXTRA="*.myorg-secret" run pp_is_secret_file "/x/.env"
  [ "$status" -eq 0 ]
}

@test "secret-file: PP_SECRET_FILE_PATTERNS replaces defaults entirely (escape hatch)" {
  # Set patterns to something that does NOT match .env
  PP_SECRET_FILE_PATTERNS="*.totallyunrelated" run pp_is_secret_file "/x/.env"
  [ "$status" -ne 0 ]
}

@test "contain: now rejects .env even when inside base" {
  echo "sk-fake" > "$PP_TEST_BASE/sub/.env"
  run pp_contain_path "$PP_TEST_BASE" "sub/.env"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: now rejects deep credentials.json" {
  echo '{}' > "$PP_TEST_BASE/sub/nested/credentials.json"
  run pp_contain_path "$PP_TEST_BASE" "sub/nested/credentials.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: still accepts non-secret files inside base" {
  run pp_contain_path "$PP_TEST_BASE" "sub/file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == "$PP_TEST_BASE"/* ]] || [[ "$output" == "$PP_TEST_BASE_REAL"/* ]]
}
