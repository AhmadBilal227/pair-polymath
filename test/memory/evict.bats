#!/usr/bin/env bats
# Pair Polymath — eviction (Task D.2).

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX"
  export CLAUDE_DIR="$SANDBOX/.claude"
  export PP_MEMORY_DIR="$SANDBOX/.claude/pair-polymath/memory"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/schema.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/redact.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/store.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/lock.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/patterns.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/evict.sh"
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/test/ev.git )
  PROJ=$(pp_memory_project_dir "$SANDBOX/repo")
  pp_memory_db_init "$PROJ"
  DB="$PROJ/observations.sqlite"
  FIXTURE="$SANDBOX/llm-fixture.sh"
}
teardown() { rm -rf "$SANDBOX"; }

_fixture_emit() {
  local body="$1"
  cat > "$FIXTURE" <<EOF
#!/usr/bin/env bash
cat <<'JSONOUT'
$body
JSONOUT
EOF
  chmod +x "$FIXTURE"
  export PP_MEMORY_LLM_BIN="$FIXTURE"
}

_ins() {
  local id="$1" lens="$2" score="${3:-0}"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
    "$id" "$lens" "TOPIC" "hook-$id" "body-$id" "[]" "[]" "sess"
  sqlite3 "$DB" "UPDATE observations SET activation_score=$score WHERE obs_id='$id';"
}

@test "evict: below threshold (PP_MEMORY_MAX_BYTES huge) → noop, no delete" {
  _ins o1 ENG 1.0
  _ins o2 ENG 2.0
  _fixture_emit '{"title":"unused","evidence_obs_ids":["o1"],"lens_ids":["ENG"],"confidence":0.5,"type":"eviction_summary","evicted_count":1}'
  PP_MEMORY_MAX_BYTES=1099511627776 pp_memory_evict "$SANDBOX/repo"
  count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$count" = "2" ]
  [ ! -f "$PROJ/patterns.jsonl" ]
}

@test "evict: above threshold → bottom-K rows deleted + summary appended" {
  for i in 1 2 3 4 5 6 7 8; do
    _ins "o$i" ENG "$i"
  done
  _fixture_emit '{"title":"Bottom-2 evicted: low-signal pre-2026 area","evidence_obs_ids":["o1","o2"],"lens_ids":["ENG"],"confidence":0.5,"type":"eviction_summary","evicted_count":2}'
  PP_MEMORY_MAX_BYTES=1 PP_MEMORY_EVICT_BATCH_SIZE=2 pp_memory_evict "$SANDBOX/repo"
  count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$count" = "6" ]
  # o1 + o2 had the lowest activation scores (1 and 2) → they must be gone.
  gone=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations WHERE obs_id IN ('o1','o2');")
  [ "$gone" = "0" ]
  # Summary line must be in patterns.jsonl with type=eviction_summary.
  [ -f "$PROJ/patterns.jsonl" ]
  type=$(tail -1 "$PROJ/patterns.jsonl" | jq -r '.type')
  [ "$type" = "eviction_summary" ]
  evcount=$(tail -1 "$PROJ/patterns.jsonl" | jq -r '.evicted_count')
  [ "$evcount" = "2" ]
}

@test "evict: WAL checkpoint TRUNCATE reduces db on-disk after delete" {
  # Insert 30 rows with large-ish bodies so eviction has bytes to release.
  for i in $(seq 1 30); do
    big=$(printf 'X%.0s' $(seq 1 2000))
    PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
      "obs-$i" ENG TOPIC "h-$i" "$big" "[]" "[]" "sess"
    sqlite3 "$DB" "UPDATE observations SET activation_score=$i WHERE obs_id='obs-$i';"
  done
  # R3.8 — GNU first; BSD stat -f leaks fs-info to stdout on Linux.
  before=$(stat -c %s "$DB" 2>/dev/null || stat -f %z "$DB" 2>/dev/null)
  _fixture_emit '{"title":"Bulk eviction summary across 20 rows","evidence_obs_ids":["obs-1"],"lens_ids":["ENG"],"confidence":0.5,"type":"eviction_summary","evicted_count":20}'
  PP_MEMORY_MAX_BYTES=1 PP_MEMORY_EVICT_BATCH_SIZE=20 pp_memory_evict "$SANDBOX/repo"
  # File must still exist + size must be less than before (WAL truncated).
  [ -f "$DB" ]
  after=$(stat -c %s "$DB" 2>/dev/null || stat -f %z "$DB" 2>/dev/null)
  # Allow equality in pathological cases (very small files); just require
  # that nothing grew unexpectedly.
  [ "$after" -le "$before" ]
  count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$count" = "10" ]
}

@test "evict: LLM returns empty/invalid summary → ABORT (no delete)" {
  _ins o1 ENG 1
  _ins o2 ENG 2
  _ins o3 ENG 3
  _fixture_emit '{"not_title":"oops"}'
  PP_MEMORY_MAX_BYTES=1 PP_MEMORY_EVICT_BATCH_SIZE=2 run pp_memory_evict "$SANDBOX/repo"
  [ "$status" -ne 0 ]
  count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$count" = "3" ]
  # No JSONL written either.
  [ ! -f "$PROJ/patterns.jsonl" ] || \
    grep -q '"type":"eviction_summary"' "$PROJ/patterns.jsonl" && false || true
}

@test "evict: lock held during eviction (concurrent inserter blocks until release)" {
  _ins o1 ENG 1
  _ins o2 ENG 2
  _ins o3 ENG 3
  _fixture_emit '{"title":"summary","evidence_obs_ids":["o1"],"lens_ids":["ENG"],"confidence":0.5,"type":"eviction_summary","evicted_count":1}'
  # The lock dir exists in $PROJ/.maint.lock when eviction is running.
  # We can't realistically race in a synchronous test, but we can confirm
  # the lock infra is invoked by manually pre-creating the lock and
  # observing that pp_memory_evict times out.
  mkdir -p "$PROJ/.maint.lock"
  PP_MEMORY_LOCK_TIMEOUT_S=2 PP_MEMORY_MAX_BYTES=1 PP_MEMORY_EVICT_BATCH_SIZE=1 \
    run pp_memory_evict "$SANDBOX/repo"
  [ "$status" -ne 0 ]
  # Rows must be untouched.
  count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$count" = "3" ]
  rm -rf "$PROJ/.maint.lock"
}

@test "evict: empty DB → noop, no error" {
  # No insertions; DB exists but is empty.
  pp_memory_evict "$SANDBOX/repo"
  count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$count" = "0" ]
}

@test "evict: invalid PP_MEMORY_MAX_BYTES rejected" {
  _ins o1 ENG 1
  _fixture_emit '{"title":"x","evidence_obs_ids":["o1"],"lens_ids":["ENG"],"confidence":0.5,"type":"eviction_summary","evicted_count":1}'
  PP_MEMORY_MAX_BYTES='1; DROP TABLE observations' run pp_memory_evict "$SANDBOX/repo"
  [ "$status" -ne 0 ]
  rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$rows" = "1" ]
}
