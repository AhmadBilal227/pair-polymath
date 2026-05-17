#!/usr/bin/env bats
# v0.5.1.1 Stage D — Task D7 — e2e fixture #2: NEARBY MENTIONS non-citable.
#
# Spec Task 17: "Frozen facts with a symbol someFromGrepOnly in the grep
# block but NOT in FILE READ. Validator allowlist must contain only the
# FILE-READ-derived symbols (someFromFileRead / decode / checkExpiry) —
# someFromGrepOnly stays in the NEARBY MENTIONS (NOT CITABLE) block."
#
# Pins Change 2's safety boundary. The inventory split is the single
# mechanism that prevents the validator from legitimizing hallucinated
# citations: if the boundary breaks, the validator accepts grep-hit
# citations even when the model never saw them in FILE READ context.
#
# We exercise the split at the helper level (pp_grounding_symbol_inventory
# returns FILE-READ-derived set ONLY) — the same contract bin/statusline.sh
# runs against when assembling the VALID SYMBOLS critique block via
# pp_extract_citations (lib/citations.sh, FILE-READ-section-only awk).
# End-to-end LLM critique coverage costs $$ in real LLM calls and is
# deferred to the eval harness; the integration boundary tested here IS
# the load-bearing surface that determines PASS vs DROP at the validator.

setup() {
  PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export PP_ROOT
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$PP_TEST_HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$CLAUDE_DIR" "$PP_CACHE_DIR"
  # citations.sh provides _PP_CITATION_STOPWORDS — grounding.sh's
  # pp_grounding_symbol_inventory references that global for the
  # stopword filter. Sourcing both keeps the two consumers aligned
  # (the same drift class the Stage A unification prevents).
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/citations.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/grounding.sh"
  PP_FIXTURE="$PP_ROOT/test/fixtures/v0.5.1.1/nearby-mentions-facts.txt"
  export PP_FIXTURE
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

# ===========================================================================
# Fixture integrity — pin the shape D7 depends on.
# ===========================================================================

@test "D7: fixture exists with the expected v0.5.1.1 schema headers" {
  [ -f "$PP_FIXTURE" ]
  head -1 "$PP_FIXTURE" | grep -qF '# facts_schema: 2'
  grep -qF 'NEARBY MENTIONS' "$PP_FIXTURE"
  grep -qF 'SYMBOL REFERENCE COUNTS' "$PP_FIXTURE"
  grep -qF 'FILE READ' "$PP_FIXTURE"
}

@test "D7: someFromGrepOnly IS in SYMBOL REFERENCE COUNTS (grep) block" {
  awk '
    /^=== SYMBOL REFERENCE COUNTS/ { in_block = 1; next }
    /^=== / { in_block = 0 }
    in_block { print }
  ' "$PP_FIXTURE" | grep -qF 'someFromGrepOnly'
}

@test "D7: someFromGrepOnly is NOT in FILE READ block" {
  # Fixture invariant: if this breaks, the boundary test below is
  # vacuous (someFromGrepOnly would legitimately be citable).
  awk '
    /^=== FILE READ/ { in_block = 1; next }
    /^=== / { in_block = 0 }
    in_block { print }
  ' "$PP_FIXTURE" > "$BATS_TMPDIR/file-read-only.txt"
  if grep -qF 'someFromGrepOnly' "$BATS_TMPDIR/file-read-only.txt"; then
    echo "fixture is broken: someFromGrepOnly leaked into FILE READ; rewrite fixture" >&2
    return 1
  fi
}

@test "D7: someFromGrepOnly IS rendered in NEARBY MENTIONS (NOT CITABLE) block" {
  awk '
    /^=== NEARBY MENTIONS/ { in_block = 1; next }
    /^=== / { in_block = 0 }
    in_block { print }
  ' "$PP_FIXTURE" | grep -qF 'someFromGrepOnly'
}

@test "D7: someFromFileRead IS in FILE READ block" {
  awk '
    /^=== FILE READ/ { in_block = 1; next }
    /^=== / { in_block = 0 }
    in_block { print }
  ' "$PP_FIXTURE" | grep -qF 'someFromFileRead'
}

# ===========================================================================
# Validator allowlist boundary — the load-bearing contract.
# Stage A's pp_grounding_symbol_inventory is the single source of truth
# for the FILE-READ-derived allowlist. The Stage C prompt-side render and
# the bin/statusline.sh critique-side VALID SYMBOLS block both derive
# from this helper (or its in-memory twin); if the boundary breaks here,
# both consumers break together.
# ===========================================================================

@test "D7: PP_INVENTORY_UNIFY_ACTIVE=1 — allowlist contains someFromFileRead (citable)" {
  # PASS-side of the boundary: a citation to someFromFileRead survives
  # because the symbol IS in the canonical allowlist.
  export PP_INVENTORY_UNIFY_ACTIVE=1
  inv=$(pp_grounding_symbol_inventory "$PP_FIXTURE")
  printf '%s\n' "$inv" | grep -qxF 'someFromFileRead'
  printf '%s\n' "$inv" | grep -qxF 'decode'
  printf '%s\n' "$inv" | grep -qxF 'checkExpiry'
}

@test "D7: PP_INVENTORY_UNIFY_ACTIVE=1 — allowlist does NOT contain someFromGrepOnly (drops with 'not in allowlist')" {
  # DROP-side of the boundary: the validator's VALID SYMBOLS block
  # (built from pp_grounding_symbol_inventory + pp_extract_citations,
  # both FILE-READ-only) MUST NOT include someFromGrepOnly. If it did,
  # the critique LLM would legitimize a hallucinated citation — exactly
  # the failure mode Change 2 fixes.
  #
  # When a lens cites someFromGrepOnly under flag=1, the critique LLM
  # sees the symbol is absent from VALID SYMBOLS and emits DROP with
  # "not in allowlist" — the retry-router classifier in
  # lib/retry-router.sh:15 maps that string to `citation_fail`.
  export PP_INVENTORY_UNIFY_ACTIVE=1
  inv=$(pp_grounding_symbol_inventory "$PP_FIXTURE")
  if printf '%s\n' "$inv" | grep -qxF 'someFromGrepOnly'; then
    echo "boundary breached: someFromGrepOnly leaked into validator allowlist" >&2
    return 1
  fi
}

@test "D7: validator allowlist boundary is invariant under flag toggle (FILE-READ-only either way)" {
  # The validator-side allowlist source (pp_grounding_symbol_inventory)
  # is FILE-READ-derived by construction — the PP_INVENTORY_UNIFY_ACTIVE
  # flag only changes the PROMPT-side rendering (legacy grep block vs
  # FILE-READ-filtered + NEARBY MENTIONS), not the validator-side
  # allowlist source. Pinning the invariant under both flag states
  # prevents future refactors from accidentally coupling the validator
  # to the grep set.
  unset PP_INVENTORY_UNIFY_ACTIVE
  inv_off=$(pp_grounding_symbol_inventory "$PP_FIXTURE")
  export PP_INVENTORY_UNIFY_ACTIVE=1
  inv_on=$(pp_grounding_symbol_inventory "$PP_FIXTURE")
  [ "$inv_off" = "$inv_on" ]
  # Both renderings must agree on the load-bearing exclusion.
  ! printf '%s\n' "$inv_off" | grep -qxF 'someFromGrepOnly'
  ! printf '%s\n' "$inv_on"  | grep -qxF 'someFromGrepOnly'
}

@test "D7: legacy v1 grep-derived allowlist WOULD have leaked someFromGrepOnly (counterfactual)" {
  # Counterfactual reminder for future readers: before Stage A, the v1
  # validator allowlist was grep-derived in some draft proposals — and
  # the spec's Change 2 explicitly calls that out as the bug. The fix
  # makes the allowlist FILE-READ-only.
  #
  # Counting symbols across the SYMBOL REFERENCE COUNTS block: if
  # someFromGrepOnly is in there (it is, by fixture construction), the
  # naive v1 grep-derived allowlist would have legitimized it. This
  # test exists to remind future readers WHY the FILE-READ-only
  # canonicalization is load-bearing — not just a refactor.
  v1_grep_count=$(awk '
    /^=== SYMBOL REFERENCE COUNTS/ { in_block = 1; next }
    /^=== / { in_block = 0 }
    in_block && /^someFromGrepOnly:/ { print }
  ' "$PP_FIXTURE" | wc -l | tr -d ' ')
  [ "$v1_grep_count" -eq 1 ]
}
