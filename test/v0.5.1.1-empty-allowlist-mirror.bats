#!/usr/bin/env bats
# v0.5.1.1 Stage A — EMPTY-ALLOWLIST EXCEPTION mirror regression.
# Spec task 6b: PROMPT (prompts/critique.md) and VALIDATOR
# (bin/statusline.sh's critique_allowlist_note block) MUST render their
# empty-state text driven by the same pp_grounding_inventory_is_empty
# helper. Without this fixture, two engineers writing
# `[ -z "$x" ]` vs `[ "$count" -eq 0 ]` would silently disagree on edge
# inputs (whitespace-only inventory; stopword-only inventory).

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}
teardown() { rm -rf "$HOME"; }

@test "mirror: prompt critique.md contains the EMPTY-ALLOWLIST EXCEPTION clause verbatim" {
  # Pins the literal text the validator-side block must mirror. If
  # prompts/critique.md ever drops/edits this clause, the mirror in
  # bin/statusline.sh becomes a dead branch — surface immediately.
  grep -q "EMPTY-ALLOWLIST EXCEPTION" "$PP_ROOT/prompts/critique.md"
}

@test "mirror: pp_grounding_inventory_is_empty drives both renders on a stopword-only inventory" {
  # Inventory of only stopwords (function, class, const, return) is
  # EFFECTIVELY empty after filtering. Both prompt + validator must
  # treat this as the EMPTY-ALLOWLIST EXCEPTION fire path.
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _facts="$PP_CACHE_DIR/facts.txt"
  cat > "$_facts" <<'EOF'
=== FILE READ (planner picked: only-stopwords.ts) ===
function return const class export
EOF
  # Helper returns 0 (true: empty) for stopword-only inputs.
  run pp_grounding_inventory_is_empty "$_facts"
  [ "$status" -eq 0 ]
}

@test "mirror: pp_grounding_inventory_is_empty returns 1 on inventory with a real symbol" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _facts="$PP_CACHE_DIR/facts.txt"
  cat > "$_facts" <<'EOF'
=== FILE READ (planner picked: real.ts) ===
const realThing = 1;
EOF
  run pp_grounding_inventory_is_empty "$_facts"
  [ "$status" -eq 1 ]
}
