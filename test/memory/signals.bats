#!/usr/bin/env bats
# Pair Polymath — windowed signals (Task C).
#
# Sandbox per test: isolated HOME, isolated cache, fresh git repo inside
# SANDBOX/repo. Salt + project hash derive cleanly per sandbox.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX"
  export CLAUDE_DIR="$SANDBOX/.claude"
  export PP_MEMORY_DIR="$SANDBOX/.claude/pair-polymath/memory"
  export PP_CACHE_DIR="$SANDBOX/.cache/pair-polymath"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/schema.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/redact.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/store.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/activation.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/lock.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/signals.sh"
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" \
      && git init -q \
      && git config user.email "a@b" \
      && git config user.name "x" \
      && git remote add origin https://github.com/test/sig.git )
  PROJ=$(pp_memory_project_dir "$SANDBOX/repo")
  pp_memory_db_init "$PROJ"
  DB="$PROJ/observations.sqlite"
}
teardown() { rm -rf "$SANDBOX"; }

# Helper: insert an obs with no body redaction, returning success.
_ins() {
  local obs_id="$1" lens="$2" hook="$3" body="$4" paths="${5:-[]}"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
    "$obs_id" "$lens" "TOPIC" "$hook" "$body" "$paths" "[]" "sess"
}

# Helper: read one signal column for one obs.
#
# F6: obs_id is bound via SQLite JSON extraction rather than shell
# interpolation. The column name is whitelisted to the four signal columns
# we ever query in this file; any other input aborts the test rather than
# falling through to a runtime SQL error. This keeps fixtures with awkward
# obs_ids (apostrophes, embedded quotes) safe to introduce later.
_sig() {
  local obs_id="$1" col="$2"
  case "$col" in
    signal_retention|signal_file_edit|signal_commit_mention|signal_test_flip) ;;
    *) printf 'unknown column: %s\n' "$col" >&2; return 2 ;;
  esac
  local id_json
  id_json=$(printf '%s' "$obs_id" | jq -Rs '.')
  sqlite3 "$DB" \
    "SELECT $col FROM observations
      WHERE obs_id = (SELECT json_extract('{\"k\":' || '$id_json' || '}', '\$.k'));"
}

# ─────────────────────────────── RETENTION (5) ───────────────────────────────

@test "retention: 1st cycle no prior state → no bump" {
  _ins "o1" "ENG" "n+1 query in users.ts" "body"
  current='[{"obs_id":"o1","lens_id":"ENG","hook":"n+1 query in users.ts"}]'
  pp_memory_tag_retention "$SANDBOX/repo" "$current"
  [ "$(_sig o1 signal_retention)" = "0" ]
  # Prior state must now exist for next cycle.
  stored=$(sqlite3 "$DB" "SELECT value FROM cycle_state WHERE key='prior_obs_lens_hook';")
  [ -n "$stored" ]
}

@test "retention: 2nd cycle with same (lens,hook) → bump by 1" {
  _ins "o1" "ENG" "n+1 query in users.ts" "body"
  current='[{"obs_id":"o1","lens_id":"ENG","hook":"n+1 query in users.ts"}]'
  pp_memory_tag_retention "$SANDBOX/repo" "$current"
  # Insert a fresh row to represent "same hook fired this cycle as a new obs"
  _ins "o2" "ENG" "n+1 query in users.ts" "body2"
  current2='[{"obs_id":"o2","lens_id":"ENG","hook":"n+1 query in users.ts"}]'
  pp_memory_tag_retention "$SANDBOX/repo" "$current2"
  [ "$(_sig o2 signal_retention)" = "1" ]
}

@test "retention: 2nd cycle different lens, same hook → no bump" {
  _ins "o1" "ENG" "n+1 query" "body"
  pp_memory_tag_retention "$SANDBOX/repo" \
    '[{"obs_id":"o1","lens_id":"ENG","hook":"n+1 query"}]'
  _ins "o2" "PROD" "n+1 query" "body2"
  pp_memory_tag_retention "$SANDBOX/repo" \
    '[{"obs_id":"o2","lens_id":"PROD","hook":"n+1 query"}]'
  [ "$(_sig o2 signal_retention)" = "0" ]
}

@test "retention: 2nd cycle same lens, different hook → no bump" {
  _ins "o1" "ENG" "n+1 query in users.ts" "b"
  pp_memory_tag_retention "$SANDBOX/repo" \
    '[{"obs_id":"o1","lens_id":"ENG","hook":"n+1 query in users.ts"}]'
  _ins "o2" "ENG" "missing index on orders.id" "b"
  pp_memory_tag_retention "$SANDBOX/repo" \
    '[{"obs_id":"o2","lens_id":"ENG","hook":"missing index on orders.id"}]'
  [ "$(_sig o2 signal_retention)" = "0" ]
}

@test "retention: 3rd cycle reinforces from 2nd (cumulative)" {
  _ins "o1" "ENG" "h" "b"
  pp_memory_tag_retention "$SANDBOX/repo" \
    '[{"obs_id":"o1","lens_id":"ENG","hook":"h"}]'
  _ins "o2" "ENG" "h" "b"
  pp_memory_tag_retention "$SANDBOX/repo" \
    '[{"obs_id":"o2","lens_id":"ENG","hook":"h"}]'
  # o2 was bumped to 1 above. Run a 3rd cycle that mentions o2 again.
  pp_memory_tag_retention "$SANDBOX/repo" \
    '[{"obs_id":"o2","lens_id":"ENG","hook":"h"}]'
  [ "$(_sig o2 signal_retention)" = "2" ]
}

# ─────────────────────────────── FILE EDIT (4) ───────────────────────────────

@test "file_edit: cited path edited within 30min → bump" {
  # Seed a tracked file and commit so HEAD exists.
  mkdir -p "$SANDBOX/repo/src"
  printf 'a\n' > "$SANDBOX/repo/src/users.ts"
  ( cd "$SANDBOX/repo" && git add src/users.ts && git commit -q -m "init users.ts" )
  # Insert obs citing the path. Backdate ts so the post-edit commit lands
  # inside the 30min window.
  _ins "o-fe" "ENG" "fix n+1" "body" '["src/users.ts"]'
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-5 minutes'),
                                       last_seen_ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-fe';"
  # Commit after the obs to satisfy the window.
  printf 'a\nb\n' > "$SANDBOX/repo/src/users.ts"
  ( cd "$SANDBOX/repo" && git add src/users.ts && git commit -q -m "edit users.ts" )
  pp_memory_tag_file_edit "$SANDBOX/repo"
  [ "$(_sig o-fe signal_file_edit)" = "1" ]
}

@test "file_edit: commit outside 30min window → no bump" {
  mkdir -p "$SANDBOX/repo/src"
  printf 'a\n' > "$SANDBOX/repo/src/users.ts"
  ( cd "$SANDBOX/repo" && git add src/users.ts && git commit -q -m "init" )
  _ins "o-fe2" "ENG" "h" "b" '["src/users.ts"]'
  # Obs is 2 hours old; we'll make the (only) edit-commit "now", clearly
  # outside the 30-minute window starting at obs_ts.
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-2 hours'),
                                       last_seen_ts=datetime('now','-2 hours')
                  WHERE obs_id='o-fe2';"
  printf 'a\nb\n' > "$SANDBOX/repo/src/users.ts"
  ( cd "$SANDBOX/repo" && git add src/users.ts && git commit -q -m "edit later" )
  pp_memory_tag_file_edit "$SANDBOX/repo"
  [ "$(_sig o-fe2 signal_file_edit)" = "0" ]
}

@test "file_edit: different file edited → no bump" {
  mkdir -p "$SANDBOX/repo/src"
  printf 'a\n' > "$SANDBOX/repo/src/users.ts"
  printf 'a\n' > "$SANDBOX/repo/src/orders.ts"
  # Backdate the init commit to 1 hour ago so it falls OUTSIDE the
  # 30-minute window we'll create around obs_ts (= now - 5 minutes).
  # Otherwise the init commit (which DOES touch users.ts) gets picked
  # up by the in-window git-log scan and the signal incorrectly fires.
  # GIT_*_DATE wants strict ISO-8601; the casual "1 hour ago" form is
  # accepted by `git log --since` but NOT by --author-date / --commit-date.
  _hour_ago=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
  GIT_AUTHOR_DATE="$_hour_ago" GIT_COMMITTER_DATE="$_hour_ago" \
    bash -c 'cd "$1" && git add . && git commit -q -m "init both"' _ "$SANDBOX/repo"
  _ins "o-fe3" "ENG" "h" "b" '["src/users.ts"]'
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-5 minutes'),
                                       last_seen_ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-fe3';"
  # Edit orders.ts only.
  printf 'a\nb\n' > "$SANDBOX/repo/src/orders.ts"
  ( cd "$SANDBOX/repo" && git add . && git commit -q -m "edit orders" )
  pp_memory_tag_file_edit "$SANDBOX/repo"
  [ "$(_sig o-fe3 signal_file_edit)" = "0" ]
}

@test "file_edit: path-escape (../etc/passwd) rejected → no bump" {
  # No real file ever exists for the escape path; we just verify the
  # signal doesn't crash and doesn't tag.
  _ins "o-fe4" "ENG" "h" "b" '["../etc/passwd"]'
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-5 minutes'),
                                       last_seen_ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-fe4';"
  pp_memory_tag_file_edit "$SANDBOX/repo"
  [ "$(_sig o-fe4 signal_file_edit)" = "0" ]
}

# ───────────────────────────── COMMIT MENTION (4) ────────────────────────────

@test "commit_mention: hook keyword matches commit message → bump" {
  printf 'a\n' > "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt && git commit -q -m "init" )
  _ins "o-cm" "ENG" "deadlock in scheduler queue" "noise body"
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-cm';"
  printf 'b\n' >> "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt \
      && git commit -q -m "investigate deadlock in scheduler" )
  pp_memory_tag_commit_mention "$SANDBOX/repo"
  [ "$(_sig o-cm signal_commit_mention)" = "1" ]
}

@test "commit_mention: body keyword matches → bump" {
  printf 'a\n' > "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt && git commit -q -m "init" )
  _ins "o-cm2" "ENG" "boring hook" "the kafka consumer rebalances under load"
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-cm2';"
  printf 'b\n' >> "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt \
      && git commit -q -m "tune kafka rebalance window" )
  pp_memory_tag_commit_mention "$SANDBOX/repo"
  [ "$(_sig o-cm2 signal_commit_mention)" = "1" ]
}

@test "commit_mention: stopword-only overlap → no bump" {
  printf 'a\n' > "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt && git commit -q -m "init" )
  # Only stopword overlaps ("with", "this", "from")
  _ins "o-cm3" "ENG" "with this thing" "from there"
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-cm3';"
  printf 'b\n' >> "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt \
      && git commit -q -m "with this from there" )
  pp_memory_tag_commit_mention "$SANDBOX/repo"
  [ "$(_sig o-cm3 signal_commit_mention)" = "0" ]
}

@test "commit_mention: <4-char overlap (fix) → no bump" {
  printf 'a\n' > "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt && git commit -q -m "init" )
  _ins "o-cm4" "ENG" "fix bug" "fix it"
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-cm4';"
  printf 'b\n' >> "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt && git commit -q -m "fix" )
  pp_memory_tag_commit_mention "$SANDBOX/repo"
  [ "$(_sig o-cm4 signal_commit_mention)" = "0" ]
}

# ───────────────────────────────── TEST FLIP (4) ──────────────────────────────

@test "test_flip: cache shows FAIL + cited path in block + mtime within 30min → bump" {
  mkdir -p "$PP_CACHE_DIR"
  # pp_memory_redact_path uses realpath under the hood, which requires the
  # path to exist on disk. In production, when an obs cites src/foo.ts AND
  # the test/lint run failed against src/foo.ts, the file DOES exist. The
  # test must mirror that — create the file so containment passes.
  mkdir -p "$SANDBOX/repo/src/handlers"
  printf 'a\n' > "$SANDBOX/repo/src/handlers/users.ts"
  cat > "$PP_CACHE_DIR/last-test-run" <<EOF
STATUS: FAIL
EXIT_CODE: 1
FAIL_BLOCK_START
src/handlers/users.ts:42:1 - error TS2304
src/handlers/users.ts:55:5 - error TS6133
FAIL_BLOCK_END
EOF
  _ins "o-tf" "ENG" "h" "b" '["src/handlers/users.ts"]'
  # Obs ts close to now (cache mtime is also now).
  pp_memory_tag_test_flip "$SANDBOX/repo"
  [ "$(_sig o-tf signal_test_flip)" = "1" ]
}

@test "test_flip: cache shows PASS → no bump" {
  mkdir -p "$PP_CACHE_DIR"
  cat > "$PP_CACHE_DIR/last-test-run" <<EOF
STATUS: PASS
EXIT_CODE: 0
EOF
  _ins "o-tf2" "ENG" "h" "b" '["src/handlers/users.ts"]'
  pp_memory_tag_test_flip "$SANDBOX/repo"
  [ "$(_sig o-tf2 signal_test_flip)" = "0" ]
}

@test "test_flip: cache mtime outside 30min window → no bump" {
  mkdir -p "$PP_CACHE_DIR"
  cat > "$PP_CACHE_DIR/last-test-run" <<EOF
STATUS: FAIL
EXIT_CODE: 1
FAIL_BLOCK_START
src/handlers/users.ts:1:1 - error
FAIL_BLOCK_END
EOF
  # Backdate cache mtime by 2 hours (clearly > 30min).
  touch -t 200001010000 "$PP_CACHE_DIR/last-test-run"
  _ins "o-tf3" "ENG" "h" "b" '["src/handlers/users.ts"]'
  pp_memory_tag_test_flip "$SANDBOX/repo"
  [ "$(_sig o-tf3 signal_test_flip)" = "0" ]
}

@test "test_flip: cache absent → noop, no error" {
  # No cache file at all.
  _ins "o-tf4" "ENG" "h" "b" '["src/handlers/users.ts"]'
  pp_memory_tag_test_flip "$SANDBOX/repo"
  [ "$?" -eq 0 ]
  [ "$(_sig o-tf4 signal_test_flip)" = "0" ]
}

# ─────────────────────────────── LOCK CONTRACT (1) ───────────────────────────

@test "lock: tag functions acquire+release lock internally" {
  # Pre-condition: no lock dir.
  [ ! -d "$PROJ/.maint.lock" ]
  _ins "o-lk" "ENG" "h" "b"
  # Call each tag function without an outer with_lock wrapper. Each must
  # succeed AND leave the lock dir cleaned up.
  pp_memory_tag_retention "$SANDBOX/repo" '[{"obs_id":"o-lk","lens_id":"ENG","hook":"h"}]'
  [ ! -d "$PROJ/.maint.lock" ]
  pp_memory_tag_file_edit "$SANDBOX/repo"
  [ ! -d "$PROJ/.maint.lock" ]
  pp_memory_tag_commit_mention "$SANDBOX/repo"
  [ ! -d "$PROJ/.maint.lock" ]
  pp_memory_tag_test_flip "$SANDBOX/repo"
  [ ! -d "$PROJ/.maint.lock" ]
}

# ─────────────────────────────── ORCHESTRATOR (1) ────────────────────────────

@test "orchestrator: run_signals_post_cycle returns 0 even with empty input" {
  pp_memory_run_signals_post_cycle "$SANDBOX/repo" '[]'
  [ "$?" -eq 0 ]
}

# ────────────────────────────── R2 REVIEW FIXES (9) ──────────────────────────
# Tests guarding the Ralph R2 fixes. One test per fix where the fix has
# observable behavior; F6 (helper SQL safety) and F9 (docs) are verified
# by adoption above and grep respectively.

# F1: deleted-file fallback in file_edit
@test "file_edit: bumps when cited file was deleted before signal run" {
  mkdir -p "$SANDBOX/repo/src"
  printf 'a\n' > "$SANDBOX/repo/src/gone.ts"
  ( cd "$SANDBOX/repo" && git add src/gone.ts && git commit -q -m "init gone.ts" )
  _ins "o-f1a" "ENG" "fix gone" "body" '["src/gone.ts"]'
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-5 minutes'),
                                       last_seen_ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-f1a';"
  # Commit a deletion AFTER the obs so it lands in the 30-min window.
  ( cd "$SANDBOX/repo" && git rm -q src/gone.ts && git commit -q -m "rm gone.ts" )
  # File no longer exists; pp_memory_redact_path would return empty here.
  # _pp_signals_safe_cited_path falls back to the literal path so the
  # signal still detects the deletion commit.
  pp_memory_tag_file_edit "$SANDBOX/repo"
  [ "$(_sig o-f1a signal_file_edit)" = "1" ]
}

# F1: deleted-file fallback in test_flip
@test "test_flip: bumps when cited file was deleted before signal run" {
  mkdir -p "$PP_CACHE_DIR" "$SANDBOX/repo/src/handlers"
  printf 'a\n' > "$SANDBOX/repo/src/handlers/gone.ts"
  ( cd "$SANDBOX/repo" && git add src/handlers/gone.ts && git commit -q -m "init" )
  cat > "$PP_CACHE_DIR/last-test-run" <<EOF
STATUS: FAIL
EXIT_CODE: 1
FAIL_BLOCK_START
src/handlers/gone.ts:1:1 - error TS2304
FAIL_BLOCK_END
EOF
  _ins "o-f1b" "ENG" "h" "b" '["src/handlers/gone.ts"]'
  # Delete the file AFTER recording the obs and the FAIL_BLOCK reference.
  rm -f "$SANDBOX/repo/src/handlers/gone.ts"
  pp_memory_tag_test_flip "$SANDBOX/repo"
  [ "$(_sig o-f1b signal_test_flip)" = "1" ]
}

# F2: invalid CURRENT_OBS_JSON preserves prior state
@test "retention: invalid JSON preserves prior state" {
  _ins "o-f2a" "ENG" "h" "b"
  good='[{"obs_id":"o-f2a","lens_id":"ENG","hook":"h"}]'
  pp_memory_tag_retention "$SANDBOX/repo" "$good"
  before=$(sqlite3 "$DB" "SELECT value FROM cycle_state WHERE key='prior_obs_lens_hook';")
  [ -n "$before" ]
  # Garbage payload — should NOT touch cycle_state.
  run pp_memory_tag_retention "$SANDBOX/repo" 'not-json-at-all'
  [ "$status" -ne 0 ]
  after=$(sqlite3 "$DB" "SELECT value FROM cycle_state WHERE key='prior_obs_lens_hook';")
  [ "$before" = "$after" ]
}

# F2: non-array JSON rejected without state mutation
@test "retention: non-array JSON rejected" {
  _ins "o-f2b" "ENG" "h" "b"
  good='[{"obs_id":"o-f2b","lens_id":"ENG","hook":"h"}]'
  pp_memory_tag_retention "$SANDBOX/repo" "$good"
  before=$(sqlite3 "$DB" "SELECT value FROM cycle_state WHERE key='prior_obs_lens_hook';")
  # Object, not array.
  run pp_memory_tag_retention "$SANDBOX/repo" '{"obs_id":"oX","lens_id":"L","hook":"h"}'
  [ "$status" -ne 0 ]
  after=$(sqlite3 "$DB" "SELECT value FROM cycle_state WHERE key='prior_obs_lens_hook';")
  [ "$before" = "$after" ]
}

# F3: stopword list no longer banishes "fix" / "query" — they fire normally.
@test "commit_mention: bumps when commit message contains 'fix N+1 query'" {
  printf 'a\n' > "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt && git commit -q -m "init" )
  # Hook contains "query" (5 chars, NOT a stopword post-F3). Commit
  # message includes "query" too. Earlier expanded stopword list would
  # have nuked both sides, dropping the signal entirely.
  _ins "o-f3" "ENG" "fix the n+1 query in users" "body"
  sqlite3 "$DB" "UPDATE observations SET ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-f3';"
  printf 'b\n' >> "$SANDBOX/repo/seed.txt"
  ( cd "$SANDBOX/repo" && git add seed.txt \
      && git commit -q -m "fix the n+1 query in users" )
  pp_memory_tag_commit_mention "$SANDBOX/repo"
  [ "$(_sig o-f3 signal_commit_mention)" = "1" ]
}

# F4: NULL cited_paths is filtered cleanly (no crash; no bump).
@test "file_edit: obs with NULL cited_paths is filtered cleanly" {
  _ins "o-f4" "ENG" "h" "b" '[]'
  # Force NULL via direct UPDATE (insert path always normalizes empty to '[]').
  sqlite3 "$DB" "UPDATE observations SET cited_paths=NULL,
                                       ts=datetime('now','-5 minutes')
                  WHERE obs_id='o-f4';"
  run pp_memory_tag_file_edit "$SANDBOX/repo"
  [ "$status" -eq 0 ]
  [ "$(_sig o-f4 signal_file_edit)" = "0" ]
}

# F5: path-prefix collision between foo.ts and foo.tsx does NOT bump.
@test "test_flip: src/foo.ts cited does NOT bump when only src/foo.tsx appears in FAIL_BLOCK" {
  mkdir -p "$PP_CACHE_DIR" "$SANDBOX/repo/src"
  printf 'a\n' > "$SANDBOX/repo/src/foo.ts"
  printf 'a\n' > "$SANDBOX/repo/src/foo.tsx"
  ( cd "$SANDBOX/repo" && git add . && git commit -q -m "init" )
  cat > "$PP_CACHE_DIR/last-test-run" <<EOF
STATUS: FAIL
EXIT_CODE: 1
FAIL_BLOCK_START
src/foo.tsx:42:1 - error TS2304
src/foo.tsx:99:1 - error TS6133
FAIL_BLOCK_END
EOF
  _ins "o-f5" "ENG" "h" "b" '["src/foo.ts"]'
  pp_memory_tag_test_flip "$SANDBOX/repo"
  [ "$(_sig o-f5 signal_test_flip)" = "0" ]
}

# F8: trap installed by pp_memory_with_lock releases lock if the inner
# function aborts via SIGINT. We can't reliably test SIGTERM-mid-sleep on
# bash 3.2 / macOS (bash sitting in waitpid on a child exits without
# running traps before unwinding). What we CAN verify is the user-visible
# guarantee: a subshell that runs through `pp_memory_with_lock`, receives
# INT during a pure-shell tight loop, and dies — leaves the lockdir gone.

# R3.6 — _pp_signals_safe_cited_path fallback hardening.
@test "safe_cited_path: R3.6 — rejects '..' anywhere" {
  out=$(_pp_signals_safe_cited_path "src/../etc/passwd" "$SANDBOX/repo")
  [ -z "$out" ]
}

@test "safe_cited_path: R3.6 — rejects leading '/'" {
  out=$(_pp_signals_safe_cited_path "/etc/passwd" "$SANDBOX/repo")
  [ -z "$out" ]
}

@test "safe_cited_path: R3.6 — rejects tilde-prefixed path" {
  out=$(_pp_signals_safe_cited_path '~/passwd' "$SANDBOX/repo")
  [ -z "$out" ]
}

@test "safe_cited_path: R3.6 — rejects '.' component" {
  out=$(_pp_signals_safe_cited_path "src/./file.ts" "$SANDBOX/repo")
  [ -z "$out" ]
}

@test "safe_cited_path: R3.6 — rejects empty path component (double slash)" {
  out=$(_pp_signals_safe_cited_path "src//file.ts" "$SANDBOX/repo")
  [ -z "$out" ]
}

@test "safe_cited_path: R3.6 — accepts ordinary relative path when file is deleted" {
  out=$(_pp_signals_safe_cited_path "src/foo.ts" "$SANDBOX/repo")
  [ "$out" = "src/foo.ts" ]
}

@test "safe_cited_path: R3.6 — accepts hidden file (leading dot on component)" {
  # .hidden is fine; only EXACTLY "." or empty are rejected.
  out=$(_pp_signals_safe_cited_path ".github/workflows/ci.yml" "$SANDBOX/repo")
  [ "$out" = ".github/workflows/ci.yml" ]
}

@test "lock: trap installed by pp_memory_with_lock cleans up on INT" {
  # Tight-loop function: stays in bash (no sleep child) so the INT trap
  # can interrupt it cleanly.
  _busy() {
    local i=0
    while [ "$i" -lt 100000 ]; do
      i=$(( i + 1 ))
    done
  }
  (
    . "$PP_ROOT/lib/memory/lock.sh"
    pp_memory_with_lock "$PROJ" _busy
  ) &
  pid=$!
  # Spin briefly until the lock has been acquired.
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    [ -d "$PROJ/.maint.lock" ] && break
    sleep 0.05
  done
  [ -d "$PROJ/.maint.lock" ]
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # Trap (or normal completion) released the lockdir.
  [ ! -d "$PROJ/.maint.lock" ]
}
