#!/usr/bin/env bats
# v0.5.1.1 Stage A — schema migration parity (spec task 15).
#
# The dual-write contract requires:
#   1. v1 READER consuming a v2 ARTIFACT: works (unknown keys ignored;
#      `# v2:` comments skipped by `grep -E '^lens'`).
#   2. v2 READER consuming a v1 ARTIFACT: works (absent schema_version
#      treated as 1; absent silent_reason normalized to empty string;
#      absent outcome treated per pre-stamp branch as legacy v1 → run
#      detector chain).
#
# These tests use hand-frozen fixtures so they exercise the parser
# contract in isolation - no statusline cycle, no LLM calls.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  FIX="$PP_ROOT/test/fixtures/v0.5.1.1"
  export FIX
}
teardown() { rm -rf "$HOME"; }

@test "migration: v1 reader (grep -E '^lens0:') consumes v2 verdict cleanly" {
  # The today-parser in bin/statusline.sh:1349 reads the verdict line via
  #   grep -E "^lens${ci}:" | head -1
  # Run that exact pattern against the v2 fixture; it must extract the
  # lens body and ignore the schema/v2 comment lines.
  local _line
  _line=$(grep -E '^lens0:' "$FIX/verdict-v2.txt" | head -1)
  [ "$_line" = "lens0: DROP — citation fails: lib/widget.ts not in allowlist" ]
}

@test "migration: v2 reader extracts the trailer hashes from a v2 verdict" {
  # Stage B's drift-invariant alarm reads the trailer.
  local _can
  _can=$(grep -E '^# v2:' "$FIX/verdict-v2.txt" \
    | sed -n 's/.*canonical_allowlist_sha8=\([0-9a-f]*\).*/\1/p')
  [ "$_can" = "abc12345" ]
}

@test "migration: v2 reader on a v1 verdict (no trailer) returns empty hash, no crash" {
  # A v1 verdict has no `# v2:` trailer. The Stage B alarm must
  # gracefully default to empty rather than throwing or treating
  # missing-as-drift.
  local _can
  _can=$(grep -E '^# v2:' "$FIX/verdict-v1.txt" 2>/dev/null \
    | sed -n 's/.*canonical_allowlist_sha8=\([0-9a-f]*\).*/\1/p' \
    || true)
  [ -z "$_can" ]
}

@test "migration: v1 OAR reader (jq -r '.outcome') extracts outcome from v2 fixture" {
  # A pre-v0.5.1.1 reader uses `jq -r '.outcome'` and is OBLIVIOUS to
  # schema_version / silent_reason. It must still get the right value.
  local _out
  _out=$(jq -r '.outcome' "$FIX/oar-labeled-v2.jsonl")
  [ "$_out" = "silent" ]
}

@test "migration: v2 OAR reader normalizes missing schema_version to 1 on v1 fixture" {
  # Stage E reads `.schema_version // 1`. v1 fixture has no field; the
  # default must trigger.
  local _sv
  _sv=$(jq -r '.schema_version // 1' "$FIX/oar-labeled-v1.jsonl")
  [ "$_sv" = "1" ]
}

@test "migration: v2 OAR reader normalizes missing silent_reason to empty string" {
  # Stage A's policy: missing silent_reason → "" (NOT null). The v2
  # reader contract MUST use `// ""` jq fallback so downstream code
  # always sees a string.
  local _sr
  _sr=$(jq -r '.silent_reason // ""' "$FIX/oar-labeled-v1.jsonl")
  [ "$_sr" = "" ]
  # Same query on v2 fixture should return the populated value.
  local _sr2
  _sr2=$(jq -r '.silent_reason // ""' "$FIX/oar-labeled-v2.jsonl")
  [ "$_sr2" = "no_ui_surface" ]
}
