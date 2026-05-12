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

@test "integration: F1 — pp_memory_top_patterns output formats into RECURRING PATTERNS block" {
  # Seed obs + extract patterns through the same flow statusline uses.
  _ins() { PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" "$1" "$2" TOPIC "$3" "$4" "[]" "[]" sess; }
  _ins o1 ENG "n+1 in users.ts"  "iterates with per-row SELECT in users.ts:42"
  _ins o2 PERF "n+1 in users.ts" "iterates with per-row SELECT in users.ts:42"
  _ins o3 ARCH "n+1 elsewhere"   "iterates with per-row SELECT in orders.ts:7"
  pp_memory_extract_patterns "$SANDBOX/repo"
  [ -f "$PROJ/patterns.jsonl" ]
  # Mirror the statusline MEMORY_BLOCK assembly. We can't shell out to
  # statusline.sh here (it pulls in too much env); the relevant piece is the
  # jq pipeline that turns top_patterns output into a text block.
  pat_json=$(pp_memory_top_patterns "$SANDBOX/repo" 5)
  [ "$pat_json" != "[]" ]
  pat_block=$(printf '%s' "$pat_json" | jq -r '
    if length == 0 then ""
    else map("[conf=\(.confidence)] \(.title) (\(.lens_ids | join(",")))") | join("\n")
    end')
  [ -n "$pat_block" ]
  # The assembled MEMORY_BLOCK gets the header prepended when pat_block is
  # non-empty.
  memory_block=$(printf '\n## RECURRING PATTERNS\n%s\n' "$pat_block")
  [[ "$memory_block" == *"## RECURRING PATTERNS"* ]]
  [[ "$memory_block" == *"recurring pattern across recent cycles"* ]]
  [[ "$memory_block" == *"[conf=0.7]"* ]]
}

@test "integration: F1 — empty patterns.jsonl yields empty pattern block" {
  pat_json=$(pp_memory_top_patterns "$SANDBOX/repo" 5)
  [ "$pat_json" = "[]" ]
  pat_block=$(printf '%s' "$pat_json" | jq -r '
    if length == 0 then "" else map(.title) | join("\n") end')
  [ -z "$pat_block" ]
}

@test "integration: F7 — fresh project DB init is idempotent on repeated calls" {
  FRESH="$SANDBOX/fresh-repo"
  mkdir -p "$FRESH"
  ( cd "$FRESH" && git init -q && git remote add origin https://github.com/test/fresh.git )
  FRESH_PROJ=$(pp_memory_project_dir "$FRESH")
  # Repeatedly init — must not error.
  pp_memory_db_init "$FRESH_PROJ"
  pp_memory_db_init "$FRESH_PROJ"
  pp_memory_db_init "$FRESH_PROJ"
  [ -f "$FRESH_PROJ/observations.sqlite" ]
  # Insert must succeed on first try without manual init.
  pp_memory_insert "$FRESH" "o-first" ENG TOPIC "hook" "body" "[]" "[]" sess
  rows=$(sqlite3 "$FRESH_PROJ/observations.sqlite" "SELECT COUNT(*) FROM observations;")
  [ "$rows" = "1" ]
}

@test "integration: F8 — concurrent pp_memory_extract_patterns produces no interleaved JSONL lines" {
  # Seed enough obs to fire the extractor.
  for i in 1 2 3 4 5; do
    PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
      "o-concur-$i" ENG TOPIC "hook$i" "body$i with token" "[]" "[]" sess
  done
  # Two concurrent extracts.
  pp_memory_extract_patterns "$SANDBOX/repo" &
  pid1=$!
  pp_memory_extract_patterns "$SANDBOX/repo" &
  pid2=$!
  wait "$pid1"
  wait "$pid2"
  [ -f "$PROJ/patterns.jsonl" ]
  # Every line must parse as JSON — no torn / interleaved writes.
  bad=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad=$((bad + 1))
  done < "$PROJ/patterns.jsonl"
  [ "$bad" = "0" ]
}

@test "integration: F6 — concurrent maint-counter increments are atomic under lock" {
  # Reset and verify the counter increments by exactly N for N concurrent
  # invocations of the locked helper (no double-counting, no lost updates).
  pp_memory_sqlite "$DB" \
    "INSERT OR REPLACE INTO cycle_state(key,value) VALUES('maintenance_cycle_counter','0');"
  # Run 12 concurrent invocations with threshold high enough to not trigger.
  # R3.10 — capture stderr per-job so we can diagnose lock-acquisition
  # timeouts on slow CI runners. The test must fail loudly with the actual
  # outputs if anything regresses.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    pp_memory_with_lock "$PROJ" _pp_memory_increment_maint_counter_locked "$PROJ" 100 \
      > "$SANDBOX/out-$i.txt" 2> "$SANDBOX/err-$i.txt" &
  done
  wait
  # Final counter value must equal exactly 12.
  final=$(pp_memory_sqlite "$DB" \
    "SELECT value FROM cycle_state WHERE key='maintenance_cycle_counter';")
  if [ "$final" != "12" ]; then
    echo "F6 FAIL — final=$final (expected 12)" >&3
    echo "out files:" >&3
    cat "$SANDBOX"/out-*.txt >&3
    echo "err files:" >&3
    cat "$SANDBOX"/err-*.txt >&3
  fi
  [ "$final" = "12" ]
}

@test "integration: F6 — atomic counter triggers maintenance exactly once at threshold" {
  pp_memory_sqlite "$DB" \
    "INSERT OR REPLACE INTO cycle_state(key,value) VALUES('maintenance_cycle_counter','0');"
  trigger_count=0
  # 24 concurrent invocations against threshold 12: counter should hit
  # threshold exactly twice → 2 TRIGGER results.
  for i in $(seq 1 24); do
    pp_memory_with_lock "$PROJ" _pp_memory_increment_maint_counter_locked "$PROJ" 12 \
      > "$SANDBOX/trig-$i.txt" 2>/dev/null &
  done
  wait
  # R3.10 — `_pp_memory_increment_maint_counter_locked` emits printf 'TRIGGER'
  # with NO trailing newline. GNU grep on Linux does NOT match `^TRIGGER$`
  # against a file whose last/only "line" lacks a newline terminator (BSD
  # grep on macOS is more permissive). Use -Fx for whole-line literal match
  # against a fixed string, which works on both. Belt + suspenders: also
  # try a direct content check via the loop below so the diagnostic on
  # failure shows exactly which files contained TRIGGER.
  trigger_count=0
  for f in "$SANDBOX"/trig-*.txt; do
    [ -f "$f" ] && [ "$(cat "$f")" = "TRIGGER" ] && \
      trigger_count=$((trigger_count + 1))
  done
  if [ "$trigger_count" != "2" ]; then
    echo "F6 TRIGGER FAIL — trigger_count=$trigger_count (expected 2)" >&3
    for f in "$SANDBOX"/trig-*.txt; do
      printf 'file %s: %s\n' "$f" "$(cat "$f")" >&3
    done
  fi
  [ "$trigger_count" = "2" ]
  # Counter should land back at 0 (last trigger reset it).
  final=$(pp_memory_sqlite "$DB" \
    "SELECT value FROM cycle_state WHERE key='maintenance_cycle_counter';")
  [ "$final" = "0" ]
}

@test "integration: F11 — code fence stripper handles json fences + trailing whitespace" {
  fence='```'
  in_lower=$(printf '%sjson\n{"patterns": []}\n%s' "$fence" "$fence")
  in_upper=$(printf '%sJSON  \n{"patterns": []}\n%s  ' "$fence" "$fence")
  in_no_fence='{"patterns": []}'
  out1=$(printf '%s' "$in_lower" | _pp_memory_strip_code_fence)
  [ "$out1" = '{"patterns": []}' ]
  out2=$(printf '%s' "$in_upper" | _pp_memory_strip_code_fence)
  [ "$out2" = '{"patterns": []}' ]
  out3=$(printf '%s' "$in_no_fence" | _pp_memory_strip_code_fence)
  [ "$out3" = '{"patterns": []}' ]
}

@test "integration: F12 — pp_memory_top_patterns ranks high-conf recent > low-conf recent" {
  # 3 patterns with same recency, different confidence.
  mkdir -p "$PROJ"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"id":"p-a","extracted_at":"%s","title":"low-conf","evidence_obs_ids":[],"lens_ids":[],"confidence":0.1}\n' "$now" > "$PROJ/patterns.jsonl"
  printf '{"id":"p-b","extracted_at":"%s","title":"high-conf","evidence_obs_ids":[],"lens_ids":[],"confidence":0.9}\n' "$now" >> "$PROJ/patterns.jsonl"
  printf '{"id":"p-c","extracted_at":"%s","title":"mid-conf","evidence_obs_ids":[],"lens_ids":[],"confidence":0.5}\n' "$now" >> "$PROJ/patterns.jsonl"
  out=$(pp_memory_top_patterns "$SANDBOX/repo" 3)
  first=$(printf '%s' "$out" | jq -r '.[0].title')
  third=$(printf '%s' "$out" | jq -r '.[2].title')
  [ "$first" = "high-conf" ]
  [ "$third" = "low-conf" ]
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
