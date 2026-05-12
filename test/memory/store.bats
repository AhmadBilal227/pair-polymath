#!/usr/bin/env bats
# Store + retrieval round-trips. Each test gets its own salt-rooted sandbox.

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
  . "$PP_ROOT/lib/memory/activation.sh"
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/test/x.git )
  PROJ=$(pp_memory_project_dir "$SANDBOX/repo")
  pp_memory_db_init "$PROJ"
}
teardown() { rm -rf "$SANDBOX"; }

@test "store: insert + select round-trip with single + double quotes survives" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
    "o-q" "ENG" "BACKEND" "hook with 'quote'" "body with \"double\" and 'single' marks" "[]" "[]" "sess1"
  row=$(sqlite3 "$PROJ/observations.sqlite" "SELECT body FROM observations WHERE obs_id='o-q';")
  [[ "$row" == *"\"double\""* ]]
  [[ "$row" == *"'single'"* ]]
  hookrow=$(sqlite3 "$PROJ/observations.sqlite" "SELECT hook FROM observations WHERE obs_id='o-q';")
  [[ "$hookrow" == *"'quote'"* ]]
}

@test "store: insert respects PP_MEMORY_REDACT=1 default (sk- token stripped)" {
  # Build a realistic-looking OpenAI token at runtime so GH Push Protection
  # doesn't reject the fixture during git push.
  prefix="sk"
  body_tail="NEVER_LEAK_THIS_1234567890abc"
  fake="${prefix}-${body_tail}"
  pp_memory_insert "$SANDBOX/repo" \
    "o-sec" "SECURITY" "SEC" "leak hook" "leaked token: $fake and more" "[]" "[]" "s"
  row=$(sqlite3 "$PROJ/observations.sqlite" "SELECT body FROM observations WHERE obs_id='o-sec';")
  [[ "$row" != *"NEVER_LEAK_THIS"* ]]
  [[ "$row" == *"REDACTED"* ]]
  red=$(sqlite3 "$PROJ/observations.sqlite" "SELECT redacted FROM observations WHERE obs_id='o-sec';")
  [ "$red" = "1" ]
}

@test "store: PP_MEMORY_REDACT=0 disables redaction (body stored raw)" {
  prefix="sk"
  body_tail="ALLOWED_FOR_TEST_abcdefghij1234567890"
  fake="${prefix}-${body_tail}"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
    "o-raw" "ENG" "T" "h" "body has $fake here" "[]" "[]" "s"
  row=$(sqlite3 "$PROJ/observations.sqlite" "SELECT body FROM observations WHERE obs_id='o-raw';")
  [[ "$row" == *"ALLOWED_FOR_TEST"* ]]
  red=$(sqlite3 "$PROJ/observations.sqlite" "SELECT redacted FROM observations WHERE obs_id='o-raw';")
  [ "$red" = "0" ]
}

@test "store: insert auto-populates obs_fts via trigger (FTS5 sync)" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
    "o-fts" "ENG" "T" "retry budget hook" "circuit breaker thresholds" "[]" "[]" "s"
  hit=$(pp_memory_sqlite "$PROJ/observations.sqlite" \
    "SELECT COUNT(*) FROM obs_fts WHERE obs_fts MATCH 'circuit';")
  [ "$hit" = "1" ]
  hit2=$(pp_memory_sqlite "$PROJ/observations.sqlite" \
    "SELECT COUNT(*) FROM obs_fts WHERE obs_fts MATCH 'budget';")
  [ "$hit2" = "1" ]
}

@test "store: pp_memory_top_k without query orders by activation_score DESC" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-lo" "ENG" "T" "h" "b-low" "[]" "[]" "s"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-hi" "ENG" "T" "h" "b-high" "[]" "[]" "s"
  pp_memory_sqlite "$PROJ/observations.sqlite" "UPDATE observations SET activation_score=10.0 WHERE obs_id='o-hi';"
  pp_memory_sqlite "$PROJ/observations.sqlite" "UPDATE observations SET activation_score=-5.0 WHERE obs_id='o-lo';"
  out=$(pp_memory_top_k "$SANDBOX/repo" 5)
  # First row in the JSON array should be o-hi.
  first=$(printf '%s' "$out" | jq -r '.[0].obs_id')
  [ "$first" = "o-hi" ]
}

@test "store: pp_memory_top_k bumps use_count + last_seen_ts in same txn" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-b" "ENG" "T" "h" "b" "[]" "[]" "s"
  before_uc=$(sqlite3 "$PROJ/observations.sqlite" "SELECT use_count FROM observations WHERE obs_id='o-b';")
  before_ls=$(sqlite3 "$PROJ/observations.sqlite" "SELECT last_seen_ts FROM observations WHERE obs_id='o-b';")
  # Force a different timestamp the second time.
  sleep 1
  pp_memory_top_k "$SANDBOX/repo" 5 >/dev/null
  after_uc=$(sqlite3 "$PROJ/observations.sqlite" "SELECT use_count FROM observations WHERE obs_id='o-b';")
  after_ls=$(sqlite3 "$PROJ/observations.sqlite" "SELECT last_seen_ts FROM observations WHERE obs_id='o-b';")
  [ "$after_uc" -gt "$before_uc" ]
  [ "$after_ls" != "$before_ls" ]
}

@test "store: pp_memory_top_k with query surfaces relevance-matched rows first (hybrid)" {
  # Two rows: one is highly active (recency-bias winner), one matches query.
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-active" "ENG" "T" "unrelated hot" "ranter fire" "[]" "[]" "s"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-relevant" "ENG" "T" "kafka rebalance" "consumer lag spike" "[]" "[]" "s"
  pp_memory_sqlite "$PROJ/observations.sqlite" "UPDATE observations SET activation_score=10.0 WHERE obs_id='o-active';"
  pp_memory_sqlite "$PROJ/observations.sqlite" "UPDATE observations SET activation_score=1.0 WHERE obs_id='o-relevant';"
  # Query strongly matches o-relevant but not o-active.
  PP_MEMORY_RETRIEVAL_ALPHA=20.0 \
    out=$(pp_memory_top_k "$SANDBOX/repo" 5 "kafka rebalance consumer")
  first=$(printf '%s' "$out" | jq -r '.[0].obs_id')
  [ "$first" = "o-relevant" ]
}

@test "store: pp_memory_top_k without alpha falls back to activation (recency bias)" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-act" "ENG" "T" "unrelated" "irrelevant content" "[]" "[]" "s"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-rel" "ENG" "T" "kafka rebalance" "consumer lag" "[]" "[]" "s"
  pp_memory_sqlite "$PROJ/observations.sqlite" "UPDATE observations SET activation_score=20.0 WHERE obs_id='o-act';"
  pp_memory_sqlite "$PROJ/observations.sqlite" "UPDATE observations SET activation_score=0.5 WHERE obs_id='o-rel';"
  # Default alpha=1.0; BM25 normalized to [0,1], can't beat a 20-point activation gap.
  out=$(pp_memory_top_k "$SANDBOX/repo" 5 "kafka")
  first=$(printf '%s' "$out" | jq -r '.[0].obs_id')
  [ "$first" = "o-act" ]
}

@test "store: pp_memory_top_k with dangerous-looking query does not break SQL" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-safe" "ENG" "T" "hook" "body" "[]" "[]" "s"
  # Single quotes, OR-injection attempt, semicolons. Should sanitize.
  run pp_memory_top_k "$SANDBOX/repo" 5 "rm 'foo' OR 1=1;--"
  [ "$status" -eq 0 ]
  # And nothing got dropped.
  cnt=$(sqlite3 "$PROJ/observations.sqlite" "SELECT COUNT(*) FROM observations;")
  [ "$cnt" = "1" ]
}

@test "store: pp_memory_top_k with empty-after-sanitize query still returns rows" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-only" "ENG" "T" "h" "b" "[]" "[]" "s"
  # Pure punctuation → sanitizer reduces to empty → fallback "x" → no match,
  # but LEFT JOIN keeps the row so we get activation-ranked output.
  out=$(pp_memory_top_k "$SANDBOX/repo" 5 '!@#$%^&*()')
  cnt=$(printf '%s' "$out" | jq 'length')
  [ "$cnt" = "1" ]
}

@test "store: pp_memory_top_k on empty db returns nothing (no error)" {
  # Fresh DB with no inserts.
  run pp_memory_top_k "$SANDBOX/repo" 5
  [ "$status" -eq 0 ]
}

@test "store: pp_memory_top_k deterministic tiebreak on identical scores (obs_id ASC)" {
  # Three rows with the same activation_score must come back ordered by
  # obs_id ASC so reproducibility is preserved across SQLite builds.
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "obs-c" "ENG" "T" "h" "b" "[]" "[]" "s"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "obs-a" "ENG" "T" "h" "b" "[]" "[]" "s"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "obs-b" "ENG" "T" "h" "b" "[]" "[]" "s"
  pp_memory_sqlite "$PROJ/observations.sqlite" \
    "UPDATE observations SET activation_score=5.0;"
  out=$(pp_memory_top_k "$SANDBOX/repo" 3)
  ids=$(printf '%s' "$out" | jq -r '.[].obs_id' | tr '\n' ' ')
  [ "$ids" = "obs-a obs-b obs-c " ]
}

@test "store: pp_memory_top_k with FTS5 operator tokens (NOT/OR/AND) does not crash" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-tok" "ENG" "T" "h" "kafka body" "[]" "[]" "s"
  # Bare operator tokens would raise an FTS5 syntax error without phrase-quoting.
  run pp_memory_top_k "$SANDBOX/repo" 5 "kafka NOT"
  [ "$status" -eq 0 ]
  run pp_memory_top_k "$SANDBOX/repo" 5 "kafka OR AND"
  [ "$status" -eq 0 ]
  run pp_memory_top_k "$SANDBOX/repo" 5 "NEAR kafka"
  [ "$status" -eq 0 ]
}

@test "store: pp_memory_top_k rejects injection in PP_MEMORY_RETRIEVAL_ALPHA" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-inj" "ENG" "T" "h" "b" "[]" "[]" "s"
  PP_MEMORY_RETRIEVAL_ALPHA="1.0; DROP TABLE observations; --" \
    run pp_memory_top_k "$SANDBOX/repo" 5 "kafka"
  [ "$status" -ne 0 ]
  cnt=$(sqlite3 "$PROJ/observations.sqlite" "SELECT COUNT(*) FROM observations;")
  [ "$cnt" = "1" ]
}

@test "store: pp_memory_top_k rejects non-integer k" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-k" "ENG" "T" "h" "b" "[]" "[]" "s"
  run pp_memory_top_k "$SANDBOX/repo" "5.5"
  [ "$status" -ne 0 ]
  run pp_memory_top_k "$SANDBOX/repo" "5; DROP"
  [ "$status" -ne 0 ]
}

@test "store: re-inserting same obs_id replaces (INSERT OR REPLACE)" {
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-dup" "ENG" "T" "h1" "b1" "[]" "[]" "s"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "o-dup" "ENG" "T" "h2" "b2" "[]" "[]" "s"
  cnt=$(sqlite3 "$PROJ/observations.sqlite" "SELECT COUNT(*) FROM observations WHERE obs_id='o-dup';")
  [ "$cnt" = "1" ]
  hook=$(sqlite3 "$PROJ/observations.sqlite" "SELECT hook FROM observations WHERE obs_id='o-dup';")
  [ "$hook" = "h2" ]
}
