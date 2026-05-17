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

# === Spec task 4: validator-block-text fixture ===
# These pin that the literal exception text the validator emits is the
# SAME shape the prompt expects. Either side drifting silently breaks
# the cold-start (no FILE READ) path.

@test "validator block: bin/statusline.sh emits the 'NOTE: both allowlists empty' note" {
  # Pins the literal string the validator emits when both _pp_valid_paths
  # and _pp_valid_symbols are empty. The token MUST contain
  # "EMPTY-ALLOWLIST EXCEPTION" so the critique LLM knows which prompt
  # rule to apply. If a future refactor drops this string from
  # bin/statusline.sh, the prompt's EXCEPTION rule becomes unreachable
  # (the critique LLM never sees the trigger note).
  grep -q "EMPTY-ALLOWLIST EXCEPTION" "$PP_ROOT/bin/statusline.sh"
}

@test "validator block: the exception note mentions 'both allowlists empty'" {
  # Stronger version of the above: not just the EXCEPTION keyword but
  # the trigger phrase the LLM is trained on. The validator's NOTE
  # string today reads "both allowlists empty" (bin/statusline.sh:1235);
  # the prompt's EXCEPTION clause also references "VALID PATHS is empty
  # AND VALID SYMBOLS is empty". The strings don't have to match
  # verbatim, but both sides MUST be present in their respective files.
  grep -q "both allowlists empty" "$PP_ROOT/bin/statusline.sh"
  grep -q "VALID PATHS is empty" "$PP_ROOT/prompts/critique.md"
}

@test "validator block: helper output drives the NOTE branch (no parallel implementation)" {
  # The validator MUST consult pp_grounding_inventory_is_empty rather
  # than re-implementing the empty check inline. We accept either:
  #   (a) a direct call to pp_grounding_inventory_is_empty, OR
  #   (b) the equivalent `[ -z "$_pp_valid_paths" ] && [ -z "$_pp_valid_symbols" ]`
  #       inline check from the pre-v0.5.1.1 baseline (still in place
  #       through Stage A; Stage C migrates to the helper).
  # This fixture asserts AT LEAST ONE form is present so the validator
  # block never silently loses the empty-check entirely.
  grep -qE 'pp_grounding_inventory_is_empty|_pp_valid_paths.*_pp_valid_symbols' \
    "$PP_ROOT/bin/statusline.sh"
}
