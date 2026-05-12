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

# Helper: insert one observation (no redaction).
_ins() {
  local id="$1" lens="$2" hook="$3" body="$4"
  PP_MEMORY_REDACT=0 pp_memory_insert "$SANDBOX/repo" \
    "$id" "$lens" "TOPIC" "$hook" "$body" "[]" "[]" "sess"
}

@test "patterns: empty obs set → no extraction, no JSONL file" {
  _fixture_emit '{"patterns":[{"title":"unused","evidence_obs_ids":["x"],"lens_ids":["A"],"confidence":0.5}]}'
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
  _fixture_emit '{"patterns":[{"title":"x","evidence_obs_ids":["o1"],"lens_ids":["ENG"],"confidence":0.72}]}'
  pp_memory_extract_patterns "$SANDBOX/repo"
  conf=$(head -1 "$PROJ/patterns.jsonl" | jq '.confidence')
  [ "$conf" = "0.72" ]
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
