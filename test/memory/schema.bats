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

@test "schema: parallel pp_memory_get_salt calls converge on one salt file" {
  # Spawn 10 concurrent salt-getters; they must all return the same string
  # and the on-disk .salt must exist exactly once.
  mkdir -p "$SANDBOX/parallel-out"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( pp_memory_get_salt > "$SANDBOX/parallel-out/salt.$i" ) &
  done
  wait
  # All ten captures non-empty and identical
  first=$(cat "$SANDBOX/parallel-out/salt.1")
  [ -n "$first" ]
  for i in 2 3 4 5 6 7 8 9 10; do
    [ "$(cat "$SANDBOX/parallel-out/salt.$i")" = "$first" ]
  done
  # Exactly one .salt file present (no .tmp leftovers).
  # Use -A so hidden files (.salt) are listed.
  count=$(ls -1A "$PP_MEMORY_DIR" | grep -c '^\.salt$' || true)
  [ "$count" = "1" ]
  leftover=$(ls -1A "$PP_MEMORY_DIR" | grep -c '\.tmp$' || true)
  [ "$leftover" = "0" ]
}

@test "schema: pp_memory_db_init creates expected schema + WAL mode" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_db_init "$SANDBOX/proj"
  [ -f "$SANDBOX/proj/observations.sqlite" ]
  # Schema has expected columns
  cols=$(sqlite3 "$SANDBOX/proj/observations.sqlite" "PRAGMA table_info(observations);" | awk -F'|' '{print $2}' | sort | tr '\n' ' ')
  [[ "$cols" == *"obs_id"* ]]
  [[ "$cols" == *"activation_score"* ]]
  [[ "$cols" == *"signal_retention"* ]]
  [[ "$cols" == *"signal_file_edit"* ]]
  [[ "$cols" == *"signal_commit_mention"* ]]
  [[ "$cols" == *"signal_test_flip"* ]]
  [[ "$cols" == *"signal_symbol_touch"* ]]
  [[ "$cols" == *"redacted"* ]]
  [[ "$cols" == *"embedding_id"* ]]
  # WAL mode
  jm=$(sqlite3 "$SANDBOX/proj/observations.sqlite" "PRAGMA journal_mode;")
  [ "$jm" = "wal" ]
}

@test "schema: pp_memory_db_init sets PRAGMA user_version = 1" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_db_init "$SANDBOX/proj"
  uv=$(sqlite3 "$SANDBOX/proj/observations.sqlite" "PRAGMA user_version;")
  [ "$uv" = "1" ]
}

@test "schema: pp_memory_db_migrate is a no-op on a v1 database" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_db_init "$SANDBOX/proj"
  run pp_memory_db_migrate "$SANDBOX/proj/observations.sqlite"
  [ "$status" -eq 0 ]
  uv=$(sqlite3 "$SANDBOX/proj/observations.sqlite" "PRAGMA user_version;")
  [ "$uv" = "1" ]
}
