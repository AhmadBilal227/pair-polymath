#!/usr/bin/env bash
# Pair Polymath — memory schema constants + salted project identity.
#
# Versioning glossary:
#   PP_MEMORY_SCHEMA_VERSION (env-level, string) — per-row tag stamped on every
#     observation. Bumps when the *row format* changes (column add/remove that
#     readers must reason about). Still "1" — FTS5 mirrors observations 1:1,
#     no row-format change.
#   PRAGMA user_version (db-level, int) — tracks DDL applied to this SQLite
#     file. Bumped to 2 by pp_memory_db_init / pp_memory_db_migrate when FTS5
#     tables + triggers exist. Used by pp_memory_db_migrate to drive forward
#     migrations on pre-existing v1 databases.

PP_MEMORY_SCHEMA_VERSION="1"
PP_MEMORY_DIR="${PP_MEMORY_DIR:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath/memory}"

# pp_memory_get_salt
# Returns the per-machine random salt. Created on first call, mode 0600.
# Same salt persists forever per HOME — uninstalling pair-polymath does NOT
# delete this file (allows memory across reinstalls).
#
# RACE-SAFE: parallel callers each write to a per-PID tmp then `ln`
# (hardlink, atomic create-or-fail) into the canonical name. Losers
# clean up their tmp; the winner's bytes are the single source of truth.
pp_memory_get_salt() {
  local sf="$PP_MEMORY_DIR/.salt"
  if [ ! -s "$sf" ]; then
    mkdir -p "$PP_MEMORY_DIR" 2>/dev/null || return 1
    chmod 700 "$PP_MEMORY_DIR" 2>/dev/null || true
    local tmp="$sf.$$.tmp"
    LC_ALL=C dd if=/dev/urandom bs=16 count=1 2>/dev/null \
      | od -An -tx1 | LC_ALL=C tr -d ' \n' > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    # Atomic create-or-keep: ln fails if target exists → loser's tmp is
    # cleaned up; winner's salt is the canonical one. No torn reads.
    if ln "$tmp" "$sf" 2>/dev/null; then
      rm -f "$tmp"
    else
      rm -f "$tmp"   # someone else won
    fi
  fi
  local salt
  salt=$(cat "$sf" 2>/dev/null) || return 1
  [ -n "$salt" ] || return 1
  printf '%s' "$salt"
}

# pp_memory_project_hash CWD
# Stdout: salted project identity hash (first 16 hex of sha1(salt || identity)).
pp_memory_project_hash() {
  local cwd="${1:-$PWD}"
  local identity=""
  if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    identity=$(git -C "$cwd" config --get remote.origin.url 2>/dev/null)
  fi
  if [ -z "$identity" ]; then
    if command -v realpath >/dev/null 2>&1; then
      identity=$(realpath "$cwd" 2>/dev/null)
    else
      identity=$(cd "$cwd" 2>/dev/null && pwd -P)
    fi
  fi
  [ -z "$identity" ] && identity="$cwd"
  local salt
  salt=$(pp_memory_get_salt)
  [ -z "$salt" ] && return 1
  printf '%s%s' "$salt" "$identity" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | LC_ALL=C cut -c1-16
}

# pp_memory_project_dir CWD
pp_memory_project_dir() {
  local h
  h=$(pp_memory_project_hash "${1:-$PWD}") || return 1
  printf '%s/projects/%s' "$PP_MEMORY_DIR" "$h"
}

# pp_memory_sqlite ARGS...
# Wrapper around sqlite3 that prepends PRAGMA trusted_schema = 1 to every
# connection so triggers can write into the obs_fts virtual table without
# SQLite's CLI defensive-mode rejecting the operation. The Apple-bundled
# sqlite3 compiles with TRUSTED_SCHEMA=OFF default; passing the pragma
# inline keeps macOS and Linux behaving identically.
pp_memory_sqlite() {
  sqlite3 -cmd "PRAGMA trusted_schema = 1;" "$@"
}

# pp_memory_db_init PROJ_DIR
# Creates SQLite DB with the v1+ schema. Idempotent. WAL mode for
# native concurrent-reader / single-writer semantics.
# Schema reserves signal_symbol_touch for v0.4 (impl deferred, column
# present now to avoid an ALTER TABLE migration later).
# FTS5 mirror table + triggers added in v2 (Task B.1).
pp_memory_db_init() {
  local proj_dir="$1"
  mkdir -p "$proj_dir" 2>/dev/null || return 1
  chmod 700 "$proj_dir" 2>/dev/null || true
  local db="$proj_dir/observations.sqlite"
  pp_memory_sqlite "$db" <<'EOF'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS observations (
  obs_id              TEXT PRIMARY KEY,
  ts                  TEXT NOT NULL,
  schema_version      TEXT NOT NULL,
  lens_id             TEXT NOT NULL,
  topic               TEXT,
  hook                TEXT,
  body                TEXT,
  cited_paths         TEXT,
  cited_symbols       TEXT,
  project_hash        TEXT,
  session_id          TEXT,
  signal_retention    INTEGER DEFAULT 0,
  signal_file_edit    INTEGER DEFAULT 0,
  signal_commit_mention INTEGER DEFAULT 0,
  signal_test_flip    INTEGER DEFAULT 0,
  signal_symbol_touch INTEGER DEFAULT 0,
  use_count           INTEGER DEFAULT 1,
  act_count           INTEGER DEFAULT 0,
  last_seen_ts        TEXT NOT NULL,
  activation_score    REAL DEFAULT 1.0,
  embedding_id        TEXT,
  redacted            INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_obs_ts ON observations(ts);
CREATE INDEX IF NOT EXISTS idx_obs_lens ON observations(lens_id);
CREATE INDEX IF NOT EXISTS idx_obs_activation ON observations(activation_score DESC);

CREATE TABLE IF NOT EXISTS cycle_state (
  key   TEXT PRIMARY KEY,
  value TEXT
);
EOF
  pp_memory_db_migrate "$db" || return 1
  chmod 600 "$db" 2>/dev/null || true
}

# _pp_memory_apply_fts5 DB_PATH
# Creates the FTS5 virtual table + sync triggers on the observations table.
# Idempotent (uses IF NOT EXISTS for everything). The triggers keep obs_fts
# in lockstep with observations: AFTER INSERT inserts the new rowid, AFTER
# DELETE issues an FTS5 'delete' command, AFTER UPDATE does both.
#
# Why FTS5 (ai-engineer R1 §9): pure activation_score top-K is recency-biased
# (recently-touched dominates new-and-relevant). Hybrid BM25+activation lets
# retrieval surface observations relevant to the CURRENT cycle's grounded
# context, not just stuff that fired recently.
_pp_memory_apply_fts5() {
  local db="$1"
  pp_memory_sqlite "$db" <<'EOF'
CREATE VIRTUAL TABLE IF NOT EXISTS obs_fts USING fts5(
  hook, body, topic,
  content='observations',
  content_rowid='rowid'
);

CREATE TRIGGER IF NOT EXISTS obs_fts_ai AFTER INSERT ON observations BEGIN
  INSERT INTO obs_fts(rowid, hook, body, topic) VALUES (new.rowid, new.hook, new.body, new.topic);
END;
CREATE TRIGGER IF NOT EXISTS obs_fts_ad AFTER DELETE ON observations BEGIN
  INSERT INTO obs_fts(obs_fts, rowid, hook, body, topic) VALUES('delete', old.rowid, old.hook, old.body, old.topic);
END;
CREATE TRIGGER IF NOT EXISTS obs_fts_au AFTER UPDATE ON observations BEGIN
  INSERT INTO obs_fts(obs_fts, rowid, hook, body, topic) VALUES('delete', old.rowid, old.hook, old.body, old.topic);
  INSERT INTO obs_fts(rowid, hook, body, topic) VALUES (new.rowid, new.hook, new.body, new.topic);
END;
EOF
}

# pp_memory_db_migrate DB_PATH
# Applies pending migrations based on PRAGMA user_version.
#
# Version log:
#   v0 → v1: first-time init (db_init already ran). Bump user_version.
#   v1 → v2: add FTS5 virtual table + sync triggers (Task B.1).
#   current: 2.
#
# Migrations are forward-only. Unknown future versions return 1 with an
# explanatory stderr so a forward-rolled DB on an older codebase fails loudly.
pp_memory_db_migrate() {
  local db="$1"
  [ -f "$db" ] || return 1
  local cur
  cur=$(pp_memory_sqlite "$db" "PRAGMA user_version;" 2>/dev/null)
  # Step through versions one at a time so a v0 → v2 cold-start runs each
  # migration in order.
  while :; do
    case "$cur" in
      0)
        pp_memory_sqlite "$db" "PRAGMA user_version = 1;"
        cur=1
        ;;
      1)
        _pp_memory_apply_fts5 "$db" || return 1
        pp_memory_sqlite "$db" "PRAGMA user_version = 2;"
        cur=2
        ;;
      2)
        return 0
        ;;
      *)
        printf 'pp_memory_db_migrate: unknown user_version %s in %s\n' "$cur" "$db" >&2
        return 1
        ;;
    esac
  done
}
