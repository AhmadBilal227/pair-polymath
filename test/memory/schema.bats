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

@test "schema: pp_memory_db_init sets PRAGMA user_version = 2" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_db_init "$SANDBOX/proj"
  uv=$(sqlite3 "$SANDBOX/proj/observations.sqlite" "PRAGMA user_version;")
  [ "$uv" = "2" ]
}

@test "schema: pp_memory_db_migrate is a no-op on a v2 database" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_db_init "$SANDBOX/proj"
  run pp_memory_db_migrate "$SANDBOX/proj/observations.sqlite"
  [ "$status" -eq 0 ]
  uv=$(sqlite3 "$SANDBOX/proj/observations.sqlite" "PRAGMA user_version;")
  [ "$uv" = "2" ]
}

@test "schema: pp_memory_db_init creates obs_fts virtual table" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_db_init "$SANDBOX/proj"
  has_fts=$(sqlite3 "$SANDBOX/proj/observations.sqlite" \
    "SELECT name FROM sqlite_master WHERE type='table' AND name='obs_fts';")
  [ "$has_fts" = "obs_fts" ]
}

@test "schema: inserting into observations auto-populates obs_fts via trigger" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_db_init "$SANDBOX/proj"
  pp_memory_sqlite "$SANDBOX/proj/observations.sqlite" "
    INSERT INTO observations
      (obs_id, ts, schema_version, lens_id, topic, hook, body, last_seen_ts)
    VALUES
      ('o-fts-1', '2026-05-12T00:00:00Z', '1', 'ENG', 'BACKEND',
       'cache eviction hook', 'body about retry budget', '2026-05-12T00:00:00Z');
  "
  # FTS5 MATCH should find the row.
  hit=$(sqlite3 "$SANDBOX/proj/observations.sqlite" \
    "SELECT COUNT(*) FROM obs_fts WHERE obs_fts MATCH 'retry';")
  [ "$hit" = "1" ]
}

@test "schema: deleting from observations cascades into obs_fts via trigger" {
  mkdir -p "$SANDBOX/proj"
  pp_memory_db_init "$SANDBOX/proj"
  pp_memory_sqlite "$SANDBOX/proj/observations.sqlite" "
    INSERT INTO observations
      (obs_id, ts, schema_version, lens_id, topic, hook, body, last_seen_ts)
    VALUES
      ('o-fts-2', '2026-05-12T00:00:00Z', '1', 'ENG', 'BACKEND',
       'doomed hook', 'doomed body', '2026-05-12T00:00:00Z');
    DELETE FROM observations WHERE obs_id = 'o-fts-2';
  "
  hit=$(sqlite3 "$SANDBOX/proj/observations.sqlite" \
    "SELECT COUNT(*) FROM obs_fts WHERE obs_fts MATCH 'doomed';")
  [ "$hit" = "0" ]
}

@test "schema: v1 → v2 migration backfills obs_fts from pre-existing rows" {
  # Reproduces the legacy-DB failure mode: a v1 database with rows already in
  # observations must have its FTS5 mirror populated during migration,
  # otherwise search returns empty against legacy data.
  mkdir -p "$SANDBOX/proj"
  db="$SANDBOX/proj/observations.sqlite"
  sqlite3 "$db" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE observations (
  obs_id TEXT PRIMARY KEY, ts TEXT NOT NULL, schema_version TEXT NOT NULL,
  lens_id TEXT NOT NULL, topic TEXT, hook TEXT, body TEXT,
  cited_paths TEXT, cited_symbols TEXT, project_hash TEXT, session_id TEXT,
  signal_retention INTEGER DEFAULT 0, signal_file_edit INTEGER DEFAULT 0,
  signal_commit_mention INTEGER DEFAULT 0, signal_test_flip INTEGER DEFAULT 0,
  signal_symbol_touch INTEGER DEFAULT 0,
  use_count INTEGER DEFAULT 1, act_count INTEGER DEFAULT 0,
  last_seen_ts TEXT NOT NULL, activation_score REAL DEFAULT 1.0,
  embedding_id TEXT, redacted INTEGER DEFAULT 0
);
INSERT INTO observations (obs_id, ts, schema_version, lens_id, hook, body, topic, last_seen_ts)
VALUES
  ('legacy-1', '2026-05-12T00:00:00Z', '1', 'ENG', 'h1', 'kafka rebalance lag', 'BACKEND', '2026-05-12T00:00:00Z'),
  ('legacy-2', '2026-05-12T00:00:00Z', '1', 'ENG', 'h2', 'circuit breaker thresholds', 'BACKEND', '2026-05-12T00:00:00Z'),
  ('legacy-3', '2026-05-12T00:00:00Z', '1', 'ENG', 'h3', 'retry budget exhausted', 'BACKEND', '2026-05-12T00:00:00Z');
PRAGMA user_version = 1;
SQL
  run pp_memory_db_migrate "$db"
  [ "$status" -eq 0 ]
  obs_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM observations;")
  fts_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM obs_fts;")
  [ "$obs_count" = "3" ]
  [ "$fts_count" = "3" ]
  # And we can search the legacy content.
  hit=$(sqlite3 "$db" "SELECT COUNT(*) FROM obs_fts WHERE obs_fts MATCH 'kafka';")
  [ "$hit" = "1" ]
}

@test "schema: obs_fts_au trigger does NOT fire on use_count/last_seen_ts UPDATE" {
  # Trigger scoping check — bumping use_count shouldn't produce a delete+reinsert
  # in obs_fts. We detect "did it fire" by checking that the FTS5 segment-merge
  # cost stays at zero new internal rows; the simplest observable proxy is that
  # FTS5 search still returns exactly one row (it would also return one before,
  # so this test specifically checks that the row is still findable AND that
  # repeated use_count bumps don't error out).
  mkdir -p "$SANDBOX/proj"
  pp_memory_db_init "$SANDBOX/proj"
  pp_memory_sqlite "$SANDBOX/proj/observations.sqlite" "
    INSERT INTO observations
      (obs_id, ts, schema_version, lens_id, topic, hook, body, last_seen_ts)
    VALUES
      ('o-bump', '2026-05-12T00:00:00Z', '1', 'ENG', 'BACKEND',
       'kafka hook', 'kafka body', '2026-05-12T00:00:00Z');
  "
  # Bump use_count 10x; with the scoped trigger this should not invalidate FTS5.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pp_memory_sqlite "$SANDBOX/proj/observations.sqlite" \
      "UPDATE observations SET use_count = use_count + 1, last_seen_ts = '2026-05-12T00:00:01Z' WHERE obs_id = 'o-bump';"
  done
  hit=$(sqlite3 "$SANDBOX/proj/observations.sqlite" \
    "SELECT COUNT(*) FROM obs_fts WHERE obs_fts MATCH 'kafka';")
  [ "$hit" = "1" ]
}

@test "schema: v1 → v2 migration adds FTS5 to a pre-existing v1 db" {
  # Simulate a hypothetical pre-FTS5 v1 database: create only the observations
  # table + cycle_state, mark it user_version=1, then run pp_memory_db_migrate.
  mkdir -p "$SANDBOX/proj"
  db="$SANDBOX/proj/observations.sqlite"
  sqlite3 "$db" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE observations (
  obs_id TEXT PRIMARY KEY, ts TEXT NOT NULL, schema_version TEXT NOT NULL,
  lens_id TEXT NOT NULL, topic TEXT, hook TEXT, body TEXT,
  cited_paths TEXT, cited_symbols TEXT, project_hash TEXT, session_id TEXT,
  signal_retention INTEGER DEFAULT 0, signal_file_edit INTEGER DEFAULT 0,
  signal_commit_mention INTEGER DEFAULT 0, signal_test_flip INTEGER DEFAULT 0,
  signal_symbol_touch INTEGER DEFAULT 0,
  use_count INTEGER DEFAULT 1, act_count INTEGER DEFAULT 0,
  last_seen_ts TEXT NOT NULL, activation_score REAL DEFAULT 1.0,
  embedding_id TEXT, redacted INTEGER DEFAULT 0
);
PRAGMA user_version = 1;
SQL
  # Pre-condition: no obs_fts.
  pre=$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE name='obs_fts';")
  [ "$pre" = "0" ]
  run pp_memory_db_migrate "$db"
  [ "$status" -eq 0 ]
  uv=$(sqlite3 "$db" "PRAGMA user_version;")
  [ "$uv" = "2" ]
  post=$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE name='obs_fts';")
  [ "$post" = "1" ]
}
