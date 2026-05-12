#!/usr/bin/env bats
# Pair Polymath — memory subsystem integration (Task D.5).
#
# End-to-end smoke that exercises store + retrieval + signals + activation
# recompute + eviction + pattern extraction, mocking LLM via PP_MEMORY_LLM_BIN.
#
# This is not the eval gate (that lives at test/eval/run-memory-gate.sh).
# This is a fast hermetic check that the public APIs compose correctly.

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
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/patterns.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/evict.sh"
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" \
      && git init -q \
      && git config user.email "x@y" \
      && git config user.name "x" \
      && git remote add origin https://github.com/test/i.git )
  PROJ=$(pp_memory_project_dir "$SANDBOX/repo")
  pp_memory_db_init "$PROJ"
  DB="$PROJ/observations.sqlite"

  # Fixture LLM emits canned patterns.
  FIXTURE="$SANDBOX/llm-fixture.sh"
  cat > "$FIXTURE" <<'EOF'
#!/usr/bin/env bash
# Distinguish pattern-extraction vs eviction-summary by inspecting the
# system prompt (first positional arg).
sys="$1"
if printf '%s' "$sys" | grep -q EVICTION; then
  cat <<'JSONOUT'
{"title":"Bulk eviction summary","evidence_obs_ids":["o-1"],"lens_ids":["ENG"],"confidence":0.5,"type":"eviction_summary","evicted_count":2}
JSONOUT
else
  cat <<'JSONOUT'
{"patterns":[{"title":"recurring pattern across recent cycles","evidence_obs_ids":["o-cycle1-ENG","o-cycle2-ENG"],"lens_ids":["ENG"],"confidence":0.7}]}
JSONOUT
fi
EOF
  chmod +x "$FIXTURE"
  export PP_MEMORY_LLM_BIN="$FIXTURE"
}
teardown() { rm -rf "$SANDBOX"; }

@test "integration: 5 cycles of observations + signals + retrieval + maintenance" {
  # Simulate 5 cycles. Each cycle: insert 2 obs from different lenses,
  # then run signals. After 3 cycles, recompute scores + extract patterns.
  for cyc in 1 2 3 4 5; do
    cur='[]'
    for lens in ENG PERF; do
      obs_id="o-cycle${cyc}-${lens}"
      hook="hook-${lens}-shared"
      body="body for cycle ${cyc} from ${lens}"
      PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
        "$obs_id" "$lens" TOPIC "$hook" "$body" "[]" "[]" "sess-$cyc"
      cur=$(jq -nc --argjson c "$cur" --arg id "$obs_id" --arg l "$lens" --arg h "$hook" \
        '$c + [{obs_id:$id, lens_id:$l, hook:$h}]')
    done
    pp_memory_run_signals_post_cycle "$SANDBOX/repo" "$cur"
  done

  total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$total" = "10" ]

  # After 5 cycles, retention should have fired for the repeated (lens,hook)
  # pairs (everything past cycle 1 is a repeat). signal_retention > 0 on
  # the later cycles.
  retention_total=$(sqlite3 "$DB" "SELECT SUM(signal_retention) FROM observations;")
  [ "$retention_total" -ge 4 ]

  # Recompute activation under lock.
  pp_memory_with_lock "$PROJ" pp_memory_recompute_scores "$SANDBOX/repo"
  any_scored=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations WHERE activation_score IS NOT NULL;")
  [ "$any_scored" = "10" ]

  # Retrieval: top-3 with query should return up to 3 rows. With the
  # shared hook, FTS5 will match all rows; ordering is hybrid.
  top=$(pp_memory_top_k "$SANDBOX/repo" 3 "hook shared")
  len=$(printf '%s' "$top" | jq 'length')
  [ "$len" = "3" ]

  # Pattern extraction should fire and write at least 1 line to JSONL.
  pp_memory_extract_patterns "$SANDBOX/repo"
  [ -f "$PROJ/patterns.jsonl" ]
  lines=$(wc -l < "$PROJ/patterns.jsonl" | tr -d ' ')
  [ "$lines" -ge 1 ]

  # Eviction with tiny threshold should evict at least 1 row.
  before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  PP_MEMORY_MAX_BYTES=1 PP_MEMORY_EVICT_BATCH_SIZE=2 pp_memory_evict "$SANDBOX/repo"
  after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$after" -lt "$before" ]
  # An eviction_summary pattern must have been appended.
  evtype=$(tail -1 "$PROJ/patterns.jsonl" | jq -r '.type // ""')
  [ "$evtype" = "eviction_summary" ]
}

@test "integration: empty cycle (no obs) is a clean noop across the stack" {
  # No insertions. Signals + maintenance must not break.
  pp_memory_run_signals_post_cycle "$SANDBOX/repo" '[]'
  pp_memory_with_lock "$PROJ" pp_memory_recompute_scores "$SANDBOX/repo"
  pp_memory_extract_patterns "$SANDBOX/repo"
  pp_memory_evict "$SANDBOX/repo"
  # DB still empty, no patterns.jsonl.
  count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$count" = "0" ]
  [ ! -f "$PROJ/patterns.jsonl" ]
}

@test "integration: inject-time redaction strips secrets from retrieved body" {
  # Insert with redaction DISABLED so the secret reaches the store.
  prefix="sk"
  tail_part="LEAKED_TOKEN_abcdefghijklmnop1234"
  fake="${prefix}-${tail_part}"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
    "o-secret" ENG TOPIC "hook" "leak: $fake here" "[]" "[]" "sess"
  # The raw store should contain the un-redacted body (we disabled it).
  raw=$(sqlite3 "$DB" "SELECT body FROM observations WHERE obs_id='o-secret';")
  [[ "$raw" == *"LEAKED_TOKEN"* ]]
  # But pp_memory_redact_body (the inject-time defense-in-depth call) MUST
  # strip it.
  redacted=$(pp_memory_redact_body "$raw")
  [[ "$redacted" != *"LEAKED_TOKEN"* ]]
  [[ "$redacted" == *"REDACTED"* ]]
}
