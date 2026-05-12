#!/usr/bin/env bats
setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX"
  export CLAUDE_DIR="$SANDBOX/.claude"
  export PP_MEMORY_DIR="$SANDBOX/.claude/pair-polymath/memory"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/schema.sh"
}
teardown() { rm -rf "$SANDBOX"; }

@test "schema: salt file is created at 0600 on first hash call" {
  mkdir -p "$SANDBOX/repo" && (cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/foo/bar.git)
  h=$(pp_memory_project_hash "$SANDBOX/repo")
  [ -n "$h" ]
  [ -f "$PP_MEMORY_DIR/.salt" ]
  perm=$(stat -f '%Lp' "$PP_MEMORY_DIR/.salt" 2>/dev/null || stat -c '%a' "$PP_MEMORY_DIR/.salt")
  [ "$perm" = "600" ]
}

@test "schema: same machine + same remote → same hash" {
  mkdir -p "$SANDBOX/repo" && (cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/foo/bar.git)
  h1=$(pp_memory_project_hash "$SANDBOX/repo")
  h2=$(pp_memory_project_hash "$SANDBOX/repo")
  [ "$h1" = "$h2" ]
}

@test "schema: different salt files → different hashes (workplace identity not portable)" {
  mkdir -p "$SANDBOX/repo" && (cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/foo/bar.git)
  h1=$(pp_memory_project_hash "$SANDBOX/repo")
  rm -f "$PP_MEMORY_DIR/.salt"
  h2=$(pp_memory_project_hash "$SANDBOX/repo")
  [ "$h1" != "$h2" ]
}

@test "schema: no git remote → falls back to realpath, salted same way" {
  mkdir -p "$SANDBOX/no-remote" && (cd "$SANDBOX/no-remote" && git init -q)
  h=$(pp_memory_project_hash "$SANDBOX/no-remote")
  [ -n "$h" ]
}

@test "schema: PP_MEMORY_SCHEMA_VERSION is the string 1" {
  [ "$PP_MEMORY_SCHEMA_VERSION" = "1" ]
}
