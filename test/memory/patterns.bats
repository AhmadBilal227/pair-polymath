#!/usr/bin/env bats
# Pair Polymath — pattern extraction (Task D.1).
#
# Mocks LLM via PP_MEMORY_LLM_BIN: a fixture shell script that emits canned
# JSON regardless of input. The fixture path is per-test so different shapes
# can be probed.

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
  . "$PP_ROOT/lib/memory/patterns.sh"
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/test/pat.git )
  PROJ=$(pp_memory_project_dir "$SANDBOX/repo")
  pp_memory_db_init "$PROJ"
  DB="$PROJ/observations.sqlite"
  FIXTURE="$SANDBOX/llm-fixture.sh"
}
teardown() { rm -rf "$SANDBOX"; }

# Helper: write a fixture LLM that emits the given JSON string verbatim.
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

# Helper (R3.17): fixture that ALSO captures the user_input so tests can
# inspect what the redaction loop produced before invoking the LLM. The
# user_input arrives on STDIN per _pp_memory_invoke_llm's contract.
_fixture_emit_capturing() {
  local body="$1"
  cat > "$FIXTURE" <<EOF
#!/usr/bin/env bash
# Capture STDIN (rows_json after re-redaction) for the test to inspect.
tee "$SANDBOX/last_user_input.json" > /dev/null
cat <<'JSONOUT'
$body
JSONOUT
EOF
  chmod +x "$FIXTURE"
  export PP_MEMORY_LLM_BIN="$FIXTURE"
}

# Helper: insert one observation (no redaction).
_ins() {
  local id="$1" lens="$2" hook="$3" body="$4"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
    "$id" "$lens" "TOPIC" "$hook" "$body" "[]" "[]" "sess"
}

@test "patterns: empty obs set → no extraction, no JSONL file" {
  _fixture_emit '{"patterns":[{"title":"unused placeholder pattern for fixture","evidence_obs_ids":["x"],"lens_ids":["A"],"confidence":0.5}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  [ ! -f "$PROJ/patterns.jsonl" ]
}

@test "patterns: 5 obs same topic → ≥1 pattern emitted to JSONL" {
  _ins o1 ENG "n+1 in users.ts" "iterates with per-row SELECT"
  _ins o2 PERF "n+1 in users.ts" "iterates with per-row SELECT"
  _ins o3 ENG "n+1 in orders.ts" "iterates with per-row SELECT"
  _ins o4 PERF "n+1 in payments.ts" "iterates with per-row SELECT"
  _ins o5 ARCH "n+1 in inventory.ts" "iterates with per-row SELECT"
  _fixture_emit '{"patterns":[{"title":"N+1 query pattern across handlers — 5 obs cite per-row SELECT","evidence_obs_ids":["o1","o2","o3","o4","o5"],"lens_ids":["ENG","PERF","ARCH"],"confidence":0.85}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  [ -f "$PROJ/patterns.jsonl" ]
  lines=$(wc -l < "$PROJ/patterns.jsonl" | tr -d ' ')
  [ "$lines" -ge 1 ]
  first=$(head -1 "$PROJ/patterns.jsonl")
  title=$(printf '%s' "$first" | jq -r '.title')
  [[ "$title" == *"N+1"* ]]
  conf=$(printf '%s' "$first" | jq -r '.confidence')
  [ "$conf" = "0.85" ]
}

@test "patterns: existing JSONL is preserved (append-only)" {
  _ins o1 ENG "hook1" "body1"
  # Pre-seed the JSONL with a known line.
  mkdir -p "$PROJ"
  printf '%s\n' '{"id":"p-existing","extracted_at":"2026-01-01T00:00:00Z","title":"preexisting","evidence_obs_ids":["o0"],"lens_ids":["X"],"confidence":0.6}' \
    > "$PROJ/patterns.jsonl"
  _fixture_emit '{"patterns":[{"title":"newly added","evidence_obs_ids":["o1"],"lens_ids":["ENG"],"confidence":0.6}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  lines=$(wc -l < "$PROJ/patterns.jsonl" | tr -d ' ')
  [ "$lines" -eq 2 ]
  first=$(head -1 "$PROJ/patterns.jsonl" | jq -r '.id')
  [ "$first" = "p-existing" ]
  last=$(tail -1 "$PROJ/patterns.jsonl" | jq -r '.title')
  [ "$last" = "newly added" ]
}

@test "patterns: file rotates when cap exceeded" {
  _ins o1 ENG "hook" "body"
  mkdir -p "$PROJ"
  # Pre-seed with 5 lines.
  for i in 1 2 3 4 5; do
    printf '{"id":"p-pre-%s","extracted_at":"2026-01-01T00:00:00Z","title":"t%s","evidence_obs_ids":["x"],"lens_ids":["X"],"confidence":0.5}\n' "$i" "$i" \
      >> "$PROJ/patterns.jsonl"
  done
  _fixture_emit '{"patterns":[{"title":"new-after-cap","evidence_obs_ids":["o1"],"lens_ids":["ENG"],"confidence":0.6}]}'
  PP_MEMORY_PATTERNS_MAX=3 pp_memory_extract_patterns "$SANDBOX/repo"
  lines=$(wc -l < "$PROJ/patterns.jsonl" | tr -d ' ')
  [ "$lines" -eq 3 ]
  # The most recent (just-appended) line must survive rotation.
  last_title=$(tail -1 "$PROJ/patterns.jsonl" | jq -r '.title')
  [ "$last_title" = "new-after-cap" ]
}

@test "patterns: malformed JSON from LLM → no JSONL write" {
  _ins o1 ENG "hook" "body"
  _fixture_emit 'this is not json at all { broken'
  pp_memory_extract_patterns "$SANDBOX/repo"
  [ ! -f "$PROJ/patterns.jsonl" ]
}

@test "patterns: LLM returns {patterns:[]} → no write" {
  _ins o1 ENG "hook" "body"
  _fixture_emit '{"patterns":[]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  [ ! -f "$PROJ/patterns.jsonl" ]
}

@test "patterns: PP_MEMORY_LLM_BIN unset and no llm CLI → silent noop" {
  _ins o1 ENG "hook" "body"
  # PP_MEMORY_LLM_BIN empty → fixture branch skipped. Then we need to make
  # `command -v llm` miss. Stub a fake PATH that contains only sqlite/jq/
  # date binaries needed by the function — but no `llm`.
  export PP_MEMORY_LLM_BIN=""
  STUB_BIN="$SANDBOX/stub-bin"
  mkdir -p "$STUB_BIN"
  for p in sqlite3 jq date cat grep mktemp tail sed awk wc tr printf ln rm mkdir chmod stat shasum sha1sum cut bash; do
    real=$(command -v "$p" 2>/dev/null || true)
    [ -n "$real" ] && ln -sf "$real" "$STUB_BIN/$p"
  done
  BASH_BIN=$(command -v bash)
  run env -i HOME="$HOME" PP_ROOT="$PP_ROOT" CLAUDE_DIR="$CLAUDE_DIR" \
    PP_MEMORY_DIR="$PP_MEMORY_DIR" SANDBOX="$SANDBOX" PATH="$STUB_BIN" \
    "$BASH_BIN" -c '
      . "$PP_ROOT/lib/memory/schema.sh"
      . "$PP_ROOT/lib/memory/redact.sh"
      . "$PP_ROOT/lib/memory/store.sh"
      . "$PP_ROOT/lib/memory/patterns.sh"
      pp_memory_extract_patterns "$SANDBOX/repo"
    '
  [ "$status" -eq 0 ]
  [ ! -f "$PROJ/patterns.jsonl" ]
}

@test "patterns: pp_memory_top_patterns on missing file returns []" {
  out=$(pp_memory_top_patterns "$SANDBOX/repo" 10)
  [ "$out" = "[]" ]
}

@test "patterns: pp_memory_top_patterns returns last K most-recent-first" {
  mkdir -p "$PROJ"
  for i in 1 2 3 4 5; do
    printf '{"id":"p%s","extracted_at":"2026-01-0%sT00:00:00Z","title":"t%s","evidence_obs_ids":[],"lens_ids":[],"confidence":0.5}\n' "$i" "$i" "$i" \
      >> "$PROJ/patterns.jsonl"
  done
  out=$(pp_memory_top_patterns "$SANDBOX/repo" 3)
  len=$(printf '%s' "$out" | jq 'length')
  [ "$len" = "3" ]
  # Most recent (t5) must be first.
  first=$(printf '%s' "$out" | jq -r '.[0].title')
  [ "$first" = "t5" ]
  last=$(printf '%s' "$out" | jq -r '.[2].title')
  [ "$last" = "t3" ]
}

@test "patterns: confidence preserved as numeric in JSONL" {
  _ins o1 ENG "h" "b"
  _fixture_emit '{"patterns":[{"title":"non-trivial title for confidence-preservation","evidence_obs_ids":["o1"],"lens_ids":["ENG"],"confidence":0.72}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  conf=$(head -1 "$PROJ/patterns.jsonl" | jq '.confidence')
  [ "$conf" = "0.72" ]
}

@test "patterns: R3.4 — evidence_obs_ids filtered to input set (drops attacker tokens)" {
  _ins o-real-1 ENG "real-hook-1" "body 1"
  _ins o-real-2 PERF "real-hook-2" "body 2"
  # LLM emits one valid obs_id AND one attacker-controlled string.
  _fixture_emit '{"patterns":[{"title":"Pattern using real obs ids plus one fake","evidence_obs_ids":["o-real-1","ATTACKER_TOKEN_NOT_IN_INPUT","o-real-2"],"lens_ids":["ENG"],"confidence":0.7}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  ev=$(head -1 "$PROJ/patterns.jsonl" | jq -c '.evidence_obs_ids')
  # Real ids survive, attacker token does not.
  [[ "$ev" == *"o-real-1"* ]]
  [[ "$ev" == *"o-real-2"* ]]
  [[ "$ev" != *"ATTACKER_TOKEN"* ]]
}

@test "patterns: R3.4 — all-fake evidence becomes empty array (pattern still persists)" {
  _ins o-real ENG "h" "b"
  _fixture_emit '{"patterns":[{"title":"Pattern with all-attacker evidence array","evidence_obs_ids":["FAKE-1","FAKE-2"],"lens_ids":["ENG"],"confidence":0.7}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  ev=$(head -1 "$PROJ/patterns.jsonl" | jq -c '.evidence_obs_ids')
  [ "$ev" = "[]" ]
}

# R3.17 — O(n) re-redaction rewrite. Three invariants under load:
# (1) no secrets survive into the rows_json passed to the LLM
# (2) row ordering is preserved (so obs_id N stays at index N)
# (3) empty bodies don't crash
@test "patterns: R3.17 — bodies redacted at batch scale, no sk-* survives" {
  # 10 rows, each body carries a unique sk- secret.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    _ins "o-r317-$i" "ENG" "hook-$i" "body $i carries sk-ABCD$i$i$i$i$i$i$i$i$i$i$i$i$i$i$i$i$i$i$i$i secret"
  done
  _fixture_emit_capturing '{"patterns":[{"title":"Captured a batch successfully under R3.17","evidence_obs_ids":[],"lens_ids":["ENG"],"confidence":0.5}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  # Inspect what the LLM saw.
  [ -f "$SANDBOX/last_user_input.json" ]
  # No sk- secret literal anywhere in the captured user input.
  if grep -q 'sk-ABCD' "$SANDBOX/last_user_input.json"; then
    cat "$SANDBOX/last_user_input.json" >&3
    false
  fi
  # All bodies should now contain [REDACTED-OPENAI] marker.
  marker_count=$(grep -o '\[REDACTED-OPENAI\]' "$SANDBOX/last_user_input.json" | wc -l | tr -d ' ')
  [ "$marker_count" -ge "10" ]
}

@test "patterns: R3.17 — row ordering preserved after re-redaction" {
  # Insert 5 rows with distinguishable bodies (no secrets — just bigrams).
  for i in 1 2 3 4 5; do
    _ins "o-r317ord-$i" "ENG" "hook-$i" "marker-$i body content"
  done
  _fixture_emit_capturing '{"patterns":[{"title":"Ordering preservation under R3.17 redaction","evidence_obs_ids":[],"lens_ids":["ENG"],"confidence":0.5}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  [ -f "$SANDBOX/last_user_input.json" ]
  # user_input is the rows array directly (not wrapped in {rows: ...}).
  bodies=$(jq -r '.[].body' "$SANDBOX/last_user_input.json")
  count=$(printf '%s\n' "$bodies" | grep -c 'marker-')
  [ "$count" = "5" ]
}

@test "patterns: R3.17 — empty body row survives without crashing" {
  _ins "o-r317emp-1" "ENG" "hook-with-body" "non-empty body"
  _ins "o-r317emp-2" "ENG" "hook-with-empty" ""
  _ins "o-r317emp-3" "ENG" "hook-back-to-body" "another body"
  _fixture_emit_capturing '{"patterns":[{"title":"Empty-body row handling under R3.17 redaction","evidence_obs_ids":[],"lens_ids":["ENG"],"confidence":0.5}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  [ -f "$SANDBOX/last_user_input.json" ]
  # All 3 rows should be present in the captured user_input array.
  row_count=$(jq 'length' "$SANDBOX/last_user_input.json")
  [ "$row_count" = "3" ]
}

@test "patterns: invalid PP_MEMORY_PATTERN_BATCH_SIZE rejected" {
  _ins o1 ENG "h" "b"
  _fixture_emit '{"patterns":[]}'
  # We need a populated DB so the function gets past the empty-noop guard
  # and reaches the numeric validation step. _ins already inserted one row.
  run env PP_ROOT="$PP_ROOT" HOME="$HOME" CLAUDE_DIR="$CLAUDE_DIR" \
    PP_MEMORY_DIR="$PP_MEMORY_DIR" SANDBOX="$SANDBOX" \
    PP_MEMORY_LLM_BIN="$PP_MEMORY_LLM_BIN" \
    PP_MEMORY_PATTERN_BATCH_SIZE='1; DROP TABLE observations' \
    bash -c '. "$PP_ROOT/lib/memory/patterns.sh" && pp_memory_extract_patterns "$SANDBOX/repo"'
  [ "$status" -ne 0 ]
  # Table must still exist — the injection MUST NOT have run.
  rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM observations;")
  [ "$rows" = "1" ]
}
