#!/usr/bin/env bash
# Pair Polymath — memory schema constants + salted project identity.

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

# pp_memory_db_init PROJ_DIR
# Creates SQLite DB with the v1 schema. Idempotent. WAL mode for
# native concurrent-reader / single-writer semantics.
# Schema reserves signal_symbol_touch for v0.4 (impl deferred, column
# present now to avoid an ALTER TABLE migration later).
pp_memory_db_init() {
  local proj_dir="$1"
  mkdir -p "$proj_dir" 2>/dev/null || return 1
  chmod 700 "$proj_dir" 2>/dev/null || true
  local db="$proj_dir/observations.sqlite"
  sqlite3 "$db" <<'EOF'
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
PRAGMA user_version = 1;
EOF
  pp_memory_db_migrate "$db" || return 1
  chmod 600 "$db" 2>/dev/null || true
}

# pp_memory_db_migrate DB_PATH
# Applies pending migrations based on PRAGMA user_version.
# v1 is the initial schema; no migrations exist yet. The function returns 0
# immediately for v1 databases. v0.4+ will add migration scripts here.
pp_memory_db_migrate() {
  local db="$1"
  [ -f "$db" ] || return 1
  local cur
  cur=$(sqlite3 "$db" "PRAGMA user_version;" 2>/dev/null)
  case "$cur" in
    0)
      # v0 → v1: first-time init, db_init already ran. Just bump user_version.
      sqlite3 "$db" "PRAGMA user_version = 1;"
      ;;
    1)
      # Current version. No-op.
      return 0
      ;;
    *)
      printf 'pp_memory_db_migrate: unknown user_version %s in %s\n' "$cur" "$db" >&2
      return 1
      ;;
  esac
}
