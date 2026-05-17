#!/usr/bin/env bats
# v0.5.1.1 Stage D Task D6 — e2e fixture #1.
#
# Spec Task 16: "Frozen facts fixture with only .sh files. Run statusline
# cycle. Assert UX_DESIGN gets outcome=silent with
# silent_reason=no_ui_surface."
#
# This pins Change 3's load-bearing mechanic: eligibility filter →
# auto-SILENT path → silent_reason stamped. If the integration breaks,
# AC #1's runtime delta CANNOT be measured downstream.
#
# Why helper-level + router-level, not the full statusline subprocess:
#   1. The full statusline cycle costs real $$ in LLM calls.
#   2. The router-level integration is the SAME contract: when
#      PP_LENS_GATES_ACTIVE=1 + facts file supplied, pp_router_pick_lenses
#      filters via pp_lens_is_eligible. The picked list is the contract
#      the rest of the cycle consumes.
#   3. The bats hermetic-HOME constraint makes a real subprocess cycle
#      hard to wire (PP_EXTERNAL_LLM=0 short-circuits before fan-out).
# Stage E (if added) can wrap this in a real subprocess flow once the
# eval harness ships.
#
# Frozen-fixture path:
#   test/fixtures/v0.5.1.1/pure-shell-facts.txt — FILE READ + git_*_paths
#   contain ONLY .sh files; no .tsx/.jsx/.css/.html/etc. UX_DESIGN's
#   path_glob eligibility set CANNOT match.

setup() {
  PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export PP_ROOT
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$PP_TEST_HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$CLAUDE_DIR" "$PP_CACHE_DIR"
  # Clean any leaked gate env from the harness.
  unset PP_ROUTER_ENABLE PP_ROUTER_MAX PP_ROUTER_MIN \
        PP_ROUTER_SURPRISE_PROB PP_ROUTER_FORCE_OUTPUT \
        PP_LENS_IDS_AVAILABLE PP_EVAL_MODE PP_RANDOM_SEED \
        PP_LENS_GATES_ACTIVE PP_LENS_GATES_TELEMETRY PP_LENS_GATES_SHADOW_FILE
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/lens-loader.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/eligibility.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/router.sh"
  pp_load_lenses 2>/dev/null || true
  PP_FIXTURE="$PP_ROOT/test/fixtures/v0.5.1.1/pure-shell-facts.txt"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

# ----------------------------------------------------------------------------
# Anchor 1: the frozen fixture is wired correctly.
# ----------------------------------------------------------------------------

@test "e2e pure-shell: fixture file exists and has the v0.5.1.1 schema header" {
  [ -f "$PP_FIXTURE" ]
  head -1 "$PP_FIXTURE" | grep -qF '# facts_schema: 2'
}

@test "e2e pure-shell: fixture's git_*_paths blocks contain ONLY .sh files" {
  # Load-bearing precondition: if a .tsx slipped into the fixture, the
  # eligibility filter could pass UX_DESIGN by accident and the test
  # below would assert the wrong invariant.
  # Extract git_diff_paths body and assert no UI-extension lines.
  diff_body=$(awk '/^# git_diff_paths$/,/^# \/git_diff_paths$/' "$PP_FIXTURE" \
                | grep -v '^# ' || true)
  untracked_body=$(awk '/^# git_untracked_paths$/,/^# \/git_untracked_paths$/' "$PP_FIXTURE" \
                     | grep -v '^# ' || true)
  combined="${diff_body}
${untracked_body}"
  # No UI-extension hits.
  if printf '%s\n' "$combined" | grep -qE '\.(tsx|jsx|css|scss|sass|less|svg|png|jpg|webp|html)$'; then
    echo "Fixture leaked a UI-extension path:"
    printf '%s\n' "$combined"
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Anchor 2: MECHANICS — eligibility-evaluator load-bearing assertions.
# These pin the spec's Change 3 contract independent of router wiring.
# ----------------------------------------------------------------------------

@test "e2e pure-shell: UX_DESIGN is INELIGIBLE on pure-shell snapshot (no_ui_surface mechanic)" {
  # The single load-bearing assertion: if eligibility returns 0 here,
  # the router does NOT filter UX_DESIGN, the analyst fires anyway, and
  # the SILENT path is never reached — AC #1 cannot then be measured.
  run pp_lens_is_eligible "UX_DESIGN" "$PP_FIXTURE"
  [ "$status" -eq 1 ]
}

@test "e2e pure-shell: PRODUCT_BIZ also INELIGIBLE on pure-shell snapshot" {
  # Per spec AC #1 carve-outs, PRODUCT_BIZ is the second hard-bar lens
  # for the -30pp DROP_excl_silent improvement. Auto-SILENT must fire
  # for it on this snapshot too.
  run pp_lens_is_eligible "PRODUCT_BIZ" "$PP_FIXTURE"
  [ "$status" -eq 1 ]
}

@test "e2e pure-shell: ENGINEERING IS eligible on the SAME snapshot" {
  # Counterpoint: the cycle isn't completely dead. ENGINEERING covers
  # **/*.sh (broad code globs per Task D4) and must still fire — that's
  # how the operator gets value from a pure-bash cycle.
  run pp_lens_is_eligible "ENGINEERING" "$PP_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "e2e pure-shell: SECURITY IS eligible on the SAME snapshot" {
  # SECURITY's globs include **/*.sh so a shell-injection in
  # bin/statusline.sh is still in-scope.
  run pp_lens_is_eligible "SECURITY" "$PP_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "e2e pure-shell: STRATEGIC_FOUNDER + COGNITIVE_FLOW (kind=always) IS eligible" {
  # Always-eligible lenses are NEVER filtered by the gate — verified
  # here on the SAME snapshot to lock the spec's carve-out from AC #1.
  run pp_lens_is_eligible "STRATEGIC_FOUNDER" "$PP_FIXTURE"
  [ "$status" -eq 0 ]
  run pp_lens_is_eligible "COGNITIVE_FLOW" "$PP_FIXTURE"
  [ "$status" -eq 0 ]
}

@test "e2e pure-shell: UX_DESIGN's silent_reasons include no_ui_surface" {
  # Round-trip pin to Stage B's per-lens enum + Task D4 JSON population.
  # When pp_router_pick_lenses drops UX_DESIGN as ineligible, the
  # downstream pipeline stamps silent_reason=no_ui_surface — that string
  # MUST exist in UX_DESIGN's silent_reasons enum, otherwise the
  # closed-enum validator would reject it.
  # PP_LENS_SILENT_REASONS[0] is UX_DESIGN (display_order=1 → first).
  printf '%s\n' "${PP_LENS_SILENT_REASONS[0]}" | tr $'\x1f' '\n' \
    | grep -qx 'no_ui_surface'
}

# ----------------------------------------------------------------------------
# Anchor 3: ROUTER INTEGRATION — gates ACTIVE + TELEMETRY on the fixture.
# The router is the consumer the rest of the cycle reads from; if the
# eligibility mechanic doesn't propagate here, AC #1 cannot be measured.
# ----------------------------------------------------------------------------

@test "e2e pure-shell: router with GATES_ACTIVE=1 DROPS UX_DESIGN from the pick" {
  # Force the router's would-be-LLM output to include UX_DESIGN so we
  # know the filter — not the LLM — is what removes it.
  export PP_ROUTER_ENABLE=1
  export PP_LENS_GATES_ACTIVE=1
  export PP_LENS_GATES_TELEMETRY=1
  export PP_LENS_GATES_SHADOW_FILE="$PP_CACHE_DIR/lens-gates-shadow.jsonl"
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nENGINEERING\nSECURITY\nSTRATEGIC_FOUNDER'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nENGINEERING\nSECURITY'
  run pp_router_pick_lenses '{}' '' "$PP_FIXTURE"
  [ "$status" -eq 0 ]
  # UX_DESIGN MUST NOT appear in the picked list — that's the auto-SILENT
  # path materialising at the router boundary.
  if printf '%s' "$output" | grep -qxF 'UX_DESIGN'; then
    echo "UX_DESIGN leaked through the gate. Output:"
    printf '%s\n' "$output"
    return 1
  fi
  # And the eligible picks DO appear.
  printf '%s' "$output" | grep -qxF 'ENGINEERING'
  printf '%s' "$output" | grep -qxF 'SECURITY'
}

@test "e2e pure-shell: telemetry shadow records UX_DESIGN as would_be_ineligible=1" {
  # Even with GATES_ACTIVE=1, the telemetry pass stamps EVERY validated
  # pick (before filtering) — so UX_DESIGN must appear in the shadow
  # JSONL with would_be_ineligible=1. This pins the mechanic the
  # operator sees in `polymath status` reports.
  export PP_ROUTER_ENABLE=1
  export PP_LENS_GATES_ACTIVE=1
  export PP_LENS_GATES_TELEMETRY=1
  export PP_LENS_GATES_SHADOW_FILE="$PP_CACHE_DIR/lens-gates-shadow.jsonl"
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nENGINEERING\nSECURITY'
  run pp_router_pick_lenses '{}' '' "$PP_FIXTURE"
  [ "$status" -eq 0 ]
  [ -f "$PP_LENS_GATES_SHADOW_FILE" ]
  grep -qF '"lens_id":"UX_DESIGN"' "$PP_LENS_GATES_SHADOW_FILE"
  grep -F '"lens_id":"UX_DESIGN"' "$PP_LENS_GATES_SHADOW_FILE" \
    | grep -qF '"would_be_ineligible":1'
  # And ENGINEERING is stamped 0 — proving the gate isn't over-broad.
  grep -F '"lens_id":"ENGINEERING"' "$PP_LENS_GATES_SHADOW_FILE" \
    | grep -qF '"would_be_ineligible":0'
}
