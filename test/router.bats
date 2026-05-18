#!/usr/bin/env bats
# Tests for lib/router.sh — LLM-based lens picker + surprise inject.
# All tests skip the real LLM call via PP_ROUTER_FORCE_OUTPUT.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  # shellcheck source=../lib/router.sh
  . "$PP_ROOT/lib/router.sh"
  # Clean env between tests.
  unset PP_ROUTER_ENABLE PP_ROUTER_MAX PP_ROUTER_MIN \
        PP_ROUTER_SURPRISE_PROB PP_ROUTER_FORCE_OUTPUT \
        PP_LENS_IDS_AVAILABLE PP_EVAL_MODE PP_RANDOM_SEED \
        PP_LENS_GATES_ACTIVE PP_LENS_GATES_TELEMETRY PP_LENS_GATES_SHADOW_FILE

  # v0.5.1.1 Stage D: source eligibility evaluator + load lenses so the
  # router's filter pass can call pp_lens_is_eligible.
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/lens-loader.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/eligibility.sh"
  pp_load_lenses 2>/dev/null || true
}

teardown() { rm -rf "$HOME"; }

# Helper: pass a newline-delimited registry via env (C5 fix).
_enable() {
  PP_LENS_IDS_AVAILABLE="$(printf '%s\n' "$@")"
  export PP_LENS_IDS_AVAILABLE
}

# Real lens IDs from lenses/*.json (UPPERCASE_UNDERSCORE convention).
# Reviewer C1 — earlier draft used fake kebab-case IDs that no real
# polymath cycle would ever see, masking the lowercasing + regex bug
# that broke the router in production. Tests now use the canonical
# registry so a future regression on case handling fails loudly.
_REAL_IDS=(UX_DESIGN ENGINEERING SECURITY PERF_FINOPS PRODUCT_BIZ COGNITIVE_FLOW STRATEGIC_FOUNDER)

# ----- ENABLE=0 / EVAL_MODE bypass (v0.3 fallback) -----

@test "pick: PP_ROUTER_ENABLE=0 returns ALL enabled lens IDs (real UPPERCASE_UNDERSCORE ids)" {
  _enable UX_DESIGN ENGINEERING SECURITY
  PP_ROUTER_ENABLE=0 run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.' )
  [ "$line_count" -eq 3 ]
  printf '%s' "$output" | grep -qxF 'UX_DESIGN'
  printf '%s' "$output" | grep -qxF 'ENGINEERING'
  printf '%s' "$output" | grep -qxF 'SECURITY'
}

@test "pick: PP_EVAL_MODE=1 bypasses router and returns ALL enabled" {
  _enable ENGINEERING SECURITY
  PP_EVAL_MODE=1 PP_ROUTER_ENABLE=1 run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.' )
  [ "$line_count" -eq 2 ]
}

@test "pick: REGRESSION — real UPPERCASE_UNDERSCORE IDs round-trip through validation (Code-Reviewer C1)" {
  _enable UX_DESIGN ENGINEERING SECURITY
  # Simulate router returning real IDs verbatim.
  PP_ROUTER_ENABLE=1 \
    PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nENGINEERING\nSECURITY' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  # All three must survive validation — earlier draft lowercased them
  # and the regex rejected the underscore, collapsing to fail-open.
  printf '%s' "$output" | grep -qxF 'UX_DESIGN'
  printf '%s' "$output" | grep -qxF 'ENGINEERING'
  printf '%s' "$output" | grep -qxF 'SECURITY'
}

# ----- MIN / MAX bounds -----

@test "pick: respects PP_ROUTER_MAX cap when router returns more" {
  _enable engineering security ux-design cognitive-flow
  PP_ROUTER_ENABLE=1 PP_ROUTER_MAX=2 \
    PP_ROUTER_FORCE_OUTPUT=$'engineering\nsecurity\nux-design\ncognitive-flow' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.' )
  [ "$line_count" -le 2 ]
}

@test "pick: respects PP_ROUTER_MIN floor when router returns fewer" {
  _enable engineering security ux-design
  PP_ROUTER_ENABLE=1 PP_ROUTER_MIN=2 \
    PP_ROUTER_FORCE_OUTPUT='engineering' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.' )
  [ "$line_count" -ge 2 ]
}

# ----- Validation: invalid IDs, normalization -----

@test "pick: rejects router output containing IDs not in enabled set" {
  _enable engineering security ux-design
  PP_ROUTER_ENABLE=1 \
    PP_ROUTER_FORCE_OUTPUT=$'engineering\nfake-lens\nsecurity' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  ! printf '%s' "$output" | grep -qF 'fake-lens'
  printf '%s' "$output" | grep -qF 'engineering'
  printf '%s' "$output" | grep -qF 'security'
}

@test "pick: I1 — trims whitespace but PRESERVES case (registry owns canonical casing)" {
  # Corrected after Code-Reviewer C1: earlier draft lowercased, which
  # broke against the real UPPERCASE_UNDERSCORE registry. Now: trim
  # only, case-sensitive match against registry. Whitespace and tabs
  # around an otherwise-valid ID are forgiven.
  _enable ENGINEERING SECURITY
  PP_ROUTER_ENABLE=1 \
    PP_ROUTER_FORCE_OUTPUT=$'  ENGINEERING   \nSECURITY ' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qxF 'ENGINEERING'
  printf '%s' "$output" | grep -qxF 'SECURITY'
}

@test "render: AI-eng C1 — prompts/router.md placeholders substitute (allowlist regression)" {
  # The router prompt declares 5 placeholders that earlier weren't in
  # PP_PROMPT_VAR_ALLOWLIST, so pp_render_prompt silently rendered them
  # empty and the router LLM saw a useless prompt. This test renders
  # the actual prompt with a synthetic signals JSON + registry, asserts
  # the substitution worked end-to-end.
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/prompt-loader.sh
  . "$PP_ROOT/lib/prompt-loader.sh"
  signals_json='{"phase":"debugging","confidence":"high","outcome":"test_failed"}'
  transcript_tail_5='USER: tests failing'$'\n''CLAUDE: looking now'
  lens_registry=$'UX_DESIGN\nENGINEERING\nSECURITY'
  PP_ROUTER_MIN=1
  PP_ROUTER_MAX=3
  export signals_json transcript_tail_5 lens_registry PP_ROUTER_MIN PP_ROUTER_MAX
  run pp_render_prompt router
  [ "$status" -eq 0 ]
  # Each placeholder MUST have its content visible in the rendered output.
  printf '%s' "$output" | grep -qF '"phase":"debugging"'
  printf '%s' "$output" | grep -qF 'USER: tests failing'
  printf '%s' "$output" | grep -qxF 'UX_DESIGN'
  printf '%s' "$output" | grep -qxF 'ENGINEERING'
  # MIN/MAX numbers substitute too (the prompt references them).
  printf '%s' "$output" | grep -qE 'MIN=1'
  printf '%s' "$output" | grep -qE 'MAX=3'
  # Negative: the literal '${signals_json}' must NOT remain in output.
  ! printf '%s' "$output" | grep -qF '${signals_json}'
}

@test "render: router prompt asks for exact registry IDs, not lowercase aliases" {
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/prompt-loader.sh
  . "$PP_ROOT/lib/prompt-loader.sh"
  signals_json='{"phase":"debugging"}'
  transcript_tail_5='USER: tests failing'
  lens_registry=$'UX_DESIGN\nENGINEERING\nSECURITY'
  PP_ROUTER_MIN=1
  PP_ROUTER_MAX=3
  export signals_json transcript_tail_5 lens_registry PP_ROUTER_MIN PP_ROUTER_MAX
  run pp_render_prompt router
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'preserving its casing'
  printf '%s' "$output" | grep -qxF 'ENGINEERING'
  printf '%s' "$output" | grep -qxF 'COGNITIVE_FLOW'
  ! printf '%s' "$output" | grep -qF 'Each line: lowercase'
}

@test "render: prompt-facing registry includes lens focus but output contract stays ID-only" {
  mkdir -p "$HOME/.claude/pair-polymath/config"
  cat > "$HOME/.claude/pair-polymath/config/lenses-enabled.txt" <<'EOF'
CFO
PRE_MORTEM
DATABASE_ENGINEER
EOF
  pp_load_lenses >/dev/null
  _enable CFO PRE_MORTEM DATABASE_ENGINEER

  run _pp_router_emit_registry
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q $'^CFO\tcost of the current technical choice'
  printf '%s\n' "$output" | grep -q $'^PRE_MORTEM\timagine the current change shipped and failed'
  printf '%s\n' "$output" | grep -q $'^DATABASE_ENGINEER\tschema design'

  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/prompt-loader.sh
  . "$PP_ROOT/lib/prompt-loader.sh"
  signals_json='{"phase":"planning"}'
  transcript_tail_5='USER: plan the rollout'
  lens_registry="$output"
  PP_ROUTER_MIN=1
  PP_ROUTER_MAX=3
  export signals_json transcript_tail_5 lens_registry PP_ROUTER_MIN PP_ROUTER_MAX
  run pp_render_prompt router
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'output only the ID before the tab'
  printf '%s' "$output" | grep -q $'CFO\tcost of the current technical choice'
}

@test "pick: GPT-C2 — accepts category-prefixed IDs like 'executive/cfo' (Phase 4 prep)" {
  _enable engineering security 'executive/cfo' 'meta/pre-mortem'
  PP_ROUTER_ENABLE=1 \
    PP_ROUTER_FORCE_OUTPUT=$'engineering\nexecutive/cfo\nmeta/pre-mortem' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qxF 'executive/cfo'
  printf '%s' "$output" | grep -qxF 'meta/pre-mortem'
}

@test "pick: I6 — strict regex rejects markdown bullets / numbered lists" {
  _enable engineering security
  PP_ROUTER_ENABLE=1 \
    PP_ROUTER_FORCE_OUTPUT=$'- engineering\n1. security' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  # Lines with leading punctuation should be filtered out before validation,
  # then fail open to all enabled instead of padding to one arbitrary lens.
  ! printf '%s' "$output" | grep -qE '^[-*0-9]'
  printf '%s' "$output" | grep -qxF 'engineering'
  printf '%s' "$output" | grep -qxF 'security'
}

@test "pick: NEWLINE-delimited output (not space-separated; advisory)" {
  _enable engineering security
  PP_ROUTER_ENABLE=1 \
    PP_ROUTER_FORCE_OUTPUT=$'engineering\nsecurity' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.')
  [ "$line_count" -eq 2 ]
  ! printf '%s' "$output" | grep -qF 'engineering security'
}

@test "pick: fail-open on empty router output returns ALL enabled" {
  _enable engineering security ux-design
  PP_ROUTER_ENABLE=1 PP_ROUTER_FORCE_OUTPUT='' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.')
  [ "$line_count" -eq 3 ]
}

@test "pick: C5 — handles newline-delimited PP_LENS_IDS_AVAILABLE correctly" {
  # Lens IDs are conventionally kebab-case (no whitespace), but the API
  # must support newline-delimited input regardless.
  PP_LENS_IDS_AVAILABLE=$'engineering\nsecurity\nux-design'
  export PP_LENS_IDS_AVAILABLE
  PP_ROUTER_ENABLE=1 PP_ROUTER_FORCE_OUTPUT=$'engineering' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'engineering'
}

# ----- Surprise inject -----

@test "surprise: SURPRISE_PROB=0 never injects (deterministic)" {
  PP_ROUTER_SURPRISE_PROB=0 PP_RANDOM_SEED=42 \
    run pp_router_surprise_inject $'engineering\nsecurity' $'ux-design\nproduct-biz\ncognitive-flow'
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.')
  [ "$line_count" -eq 2 ]
}

@test "surprise: SURPRISE_PROB=1.0 always injects exactly one off-discipline lens" {
  PP_ROUTER_SURPRISE_PROB=1.0 PP_RANDOM_SEED=42 \
    run pp_router_surprise_inject $'engineering' $'ux-design\nproduct-biz\ncognitive-flow'
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.')
  [ "$line_count" -eq 2 ]
}

@test "surprise: I4 — accepts AND emits newline-delimited (consistent API)" {
  PP_ROUTER_SURPRISE_PROB=0 \
    run pp_router_surprise_inject $'engineering\nsecurity' $'ux-design\nproduct-biz'
  [ "$status" -eq 0 ]
  # Output should NOT be space-separated
  ! printf '%s' "$output" | grep -qF 'engineering security'
  # Should be 2 newline-separated lines
  line_count=$(printf '%s\n' "$output" | grep -c '^.')
  [ "$line_count" -eq 2 ]
}

@test "surprise: respects PP_ROUTER_SURPRISE_MAX_TOTAL cap" {
  # Picked set is already at the cap; surprise must NOT add more.
  PP_ROUTER_SURPRISE_PROB=1.0 PP_RANDOM_SEED=42 PP_ROUTER_SURPRISE_MAX_TOTAL=3 \
    run pp_router_surprise_inject $'engineering\nsecurity\nux-design' $'product-biz\ncognitive-flow'
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.')
  [ "$line_count" -le 3 ]
}

@test "router: P2.5 — _pp_router_llm_call does NOT hang when coreutils absent (GPT-C1)" {
  # Simulate macOS-without-coreutils: PATH has bash/grep/sed/etc but
  # no timeout/gtimeout. Mock 'llm' to sleep 30s. The fallback path
  # MUST return within PP_ROUTER_TIMEOUT_S + slop, never hang.
  _mockdir=$(mktemp -d)
  cat > "$_mockdir/llm" <<'MOCKEOF'
#!/bin/sh
sleep 30
echo "should-never-print"
MOCKEOF
  chmod +x "$_mockdir/llm"
  # Build a PATH with basic utilities but excluding timeout/gtimeout.
  # GPT-C4 from plan review: PATH=/dev/null breaks bats itself; use a
  # real PATH minus the timeout binaries. Include BOTH /usr/bin and /bin
  # so sleep (in /bin on macOS) and grep (in /usr/bin) are both findable.
  _basebin="/usr/bin:/bin"
  # Strip any /usr/local/bin or /opt/homebrew/bin paths where timeout/
  # gtimeout could live.
  _t0=$(date +%s)
  PATH="$_mockdir:$_basebin" \
    PP_ROUTER_TIMEOUT_S=2 \
    run _pp_router_llm_call '{"phase":"unknown"}' "USER: probe"
  _t1=$(date +%s)
  _elapsed=$((_t1 - _t0))
  rm -rf "$_mockdir"
  # Must complete in ≤5s (2s timeout + 3s slop), NEVER in 30s+
  if [ "$_elapsed" -gt 5 ]; then
    echo "elapsed=$_elapsed (expected <=5; mock llm sleeps 30s — fallback didn't bound)" >&2
    return 1
  fi
}

@test "pick: C4 — PP_ROUTER_ENABLE=0 produces identical output to fan-out-all" {
  # When the router is disabled, the picked set must EQUAL the enabled
  # set (one per line, in registry order). This is the byte-identical
  # v0.3 fallback invariant the GPT plan review (C4) demanded a test for.
  _enable engineering security ux-design perf-finops product-biz cognitive-flow strategic-founder
  PP_ROUTER_ENABLE=0 run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  # Picked must be the same 7 entries in the same order as enabled set.
  expected=$(printf '%s\n' engineering security ux-design perf-finops product-biz cognitive-flow strategic-founder)
  [ "$output" = "$expected" ]
}

@test "pick: C4 — PP_ROUTER_ENABLE=1 with fail-open also returns full enabled set" {
  # When the router LLM is unavailable / EMPTY result, fail-open returns
  # all enabled. This + the C4 byte-identical test above together cover
  # the safety net: 'router can never silently silence polymath'.
  _enable engineering security ux-design
  PP_ROUTER_ENABLE=1 PP_ROUTER_FORCE_OUTPUT='' run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  expected=$(printf '%s\n' engineering security ux-design)
  [ "$output" = "$expected" ]
}

@test "surprise: doesn't duplicate when injected lens already in picked set" {
  # If somehow not_picked contains a lens already in picked, dedupe.
  PP_ROUTER_SURPRISE_PROB=1.0 PP_RANDOM_SEED=42 \
    run pp_router_surprise_inject $'engineering' $'engineering\nsecurity'
  [ "$status" -eq 0 ]
  # 'engineering' should appear at most once
  count=$(printf '%s\n' "$output" | grep -c '^engineering$')
  [ "$count" -eq 1 ]
}

# ============================================================================
# v0.5.1.1 Stage D — eligibility filter in pp_router_pick_lenses
# ============================================================================

@test "Stage D router (gates OFF): byte-identical to v0.5.0 (no facts arg)" {
  export PP_LENS_GATES_ACTIVE=0
  export PP_LENS_GATES_TELEMETRY=0
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_ENABLE=1
  run pp_router_pick_lenses '{}' ''
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qxF 'UX_DESIGN'
  printf '%s' "$output" | grep -qxF 'ENGINEERING'
  printf '%s' "$output" | grep -qxF 'SECURITY'
}

@test "Stage D router (gates ON, no facts): no filtering applied (fail-open)" {
  export PP_LENS_GATES_ACTIVE=1
  export PP_LENS_GATES_TELEMETRY=0
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_ENABLE=1
  # No facts file passed → eligibility evaluation skipped.
  run pp_router_pick_lenses '{}' ''
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qxF 'UX_DESIGN'
}

@test "Stage D router (gates ON, with facts): UX_DESIGN dropped on pure-shell snapshot" {
  export PP_LENS_GATES_ACTIVE=1
  export PP_LENS_GATES_TELEMETRY=0
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nENGINEERING\nSECURITY\nPERF_FINOPS'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_ENABLE=1
  # Build a pure-shell facts file.
  facts_file="$BATS_TMPDIR/router-pure-shell-facts.txt"
  cat > "$facts_file" <<'EOF'
# facts_schema: 2
=== FILE READ (planner picked: bin/statusline.sh) ===
(omitted)

# git_diff_paths
bin/statusline.sh
lib/router.sh
# /git_diff_paths

# git_untracked_paths
# /git_untracked_paths

# git_staged_paths
# /git_staged_paths
EOF
  run pp_router_pick_lenses '{}' '' "$facts_file"
  [ "$status" -eq 0 ]
  # UX_DESIGN should be filtered out; replacement drawn from PERF_FINOPS
  # (next-ranked eligible in PP_LENS_IDS_AVAILABLE order).
  if printf '%s' "$output" | grep -qxF 'UX_DESIGN'; then
    echo "UX_DESIGN should have been filtered. Got: $output"
    return 1
  fi
  printf '%s' "$output" | grep -qxF 'ENGINEERING'
  printf '%s' "$output" | grep -qxF 'SECURITY'
  # And the replacement:
  printf '%s' "$output" | grep -qxF 'PERF_FINOPS'
}

@test "Stage D router (gates ON): no eligible replacement -> fan-out runs smaller" {
  export PP_LENS_GATES_ACTIVE=1
  export PP_LENS_GATES_TELEMETRY=0
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nPRODUCT_BIZ'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nPRODUCT_BIZ'
  export PP_ROUTER_ENABLE=1
  # Pure-shell snapshot: NEITHER UX_DESIGN nor PRODUCT_BIZ eligible, and
  # no replacement candidates available.
  facts_file="$BATS_TMPDIR/router-tiny-pool-facts.txt"
  cat > "$facts_file" <<'EOF'
# facts_schema: 2
=== FILE READ (planner picked: bin/statusline.sh) ===
(omitted)

# git_diff_paths
bin/statusline.sh
# /git_diff_paths

# git_untracked_paths
# /git_untracked_paths

# git_staged_paths
# /git_staged_paths
EOF
  # Must NOT crash; must NOT silently fall open to all-enabled.
  run pp_router_pick_lenses '{}' '' "$facts_file"
  [ "$status" -eq 0 ]
  # Output may be empty; UX_DESIGN and PRODUCT_BIZ must NOT appear.
  if printf '%s' "$output" | grep -qxF 'UX_DESIGN'; then
    echo "UX_DESIGN should have been filtered"
    return 1
  fi
  if printf '%s' "$output" | grep -qxF 'PRODUCT_BIZ'; then
    echo "PRODUCT_BIZ should have been filtered"
    return 1
  fi
}

@test "Stage D router (gates ON): STRATEGIC_FOUNDER (kind=always) passes filter" {
  export PP_LENS_GATES_ACTIVE=1
  export PP_LENS_GATES_TELEMETRY=0
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nSTRATEGIC_FOUNDER'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nSTRATEGIC_FOUNDER'
  export PP_ROUTER_ENABLE=1
  facts_file="$BATS_TMPDIR/router-sf-facts.txt"
  cat > "$facts_file" <<'EOF'
# facts_schema: 2
=== FILE READ (planner picked: bin/statusline.sh) ===
(omitted)

# git_diff_paths
bin/statusline.sh
# /git_diff_paths

# git_untracked_paths
# /git_untracked_paths

# git_staged_paths
# /git_staged_paths
EOF
  run pp_router_pick_lenses '{}' '' "$facts_file"
  [ "$status" -eq 0 ]
  # UX_DESIGN filtered out, STRATEGIC_FOUNDER (always-eligible) survives.
  if printf '%s' "$output" | grep -qxF 'UX_DESIGN'; then
    echo "UX_DESIGN should have been filtered"
    return 1
  fi
  printf '%s' "$output" | grep -qxF 'STRATEGIC_FOUNDER'
}

@test "Stage D router (telemetry ON, active OFF): would_be_ineligible stamped (shadow)" {
  export PP_LENS_GATES_ACTIVE=0
  export PP_LENS_GATES_TELEMETRY=1
  export PP_LENS_GATES_SHADOW_FILE="$BATS_TMPDIR/router-shadow.jsonl"
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_ENABLE=1
  rm -f "$PP_LENS_GATES_SHADOW_FILE"
  facts_file="$BATS_TMPDIR/router-shadow-facts.txt"
  cat > "$facts_file" <<'EOF'
# facts_schema: 2
=== FILE READ (planner picked: bin/statusline.sh) ===
(omitted)

# git_diff_paths
bin/statusline.sh
# /git_diff_paths

# git_untracked_paths
# /git_untracked_paths

# git_staged_paths
# /git_staged_paths
EOF
  run pp_router_pick_lenses '{}' '' "$facts_file"
  [ "$status" -eq 0 ]
  # Behavior unchanged — UX_DESIGN survives picks (active=0).
  printf '%s' "$output" | grep -qxF 'UX_DESIGN'
  # But the shadow file records UX_DESIGN as would_be_ineligible=1.
  [ -f "$PP_LENS_GATES_SHADOW_FILE" ]
  grep -q '"lens_id":"UX_DESIGN"' "$PP_LENS_GATES_SHADOW_FILE"
  grep -q '"would_be_ineligible":1' "$PP_LENS_GATES_SHADOW_FILE"
}

@test "Stage D router (gates ON): replacement draws ONE candidate, not all remaining" {
  # If the picker dropped UX_DESIGN AND PRODUCT_BIZ as ineligible, we
  # should draw at most 2 replacements (one per dropped pick), NOT flood
  # the enabled set in.
  export PP_LENS_GATES_ACTIVE=1
  export PP_LENS_GATES_TELEMETRY=0
  export PP_ROUTER_MAX=3
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nPRODUCT_BIZ\nENGINEERING\nSECURITY\nPERF_FINOPS\nSTRATEGIC_FOUNDER\nCOGNITIVE_FLOW'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nPRODUCT_BIZ\nENGINEERING'
  export PP_ROUTER_ENABLE=1
  facts_file="$BATS_TMPDIR/router-replace-facts.txt"
  cat > "$facts_file" <<'EOF'
# facts_schema: 2
=== FILE READ (planner picked: bin/statusline.sh) ===
(omitted)

# git_diff_paths
bin/statusline.sh
# /git_diff_paths

# git_untracked_paths
# /git_untracked_paths

# git_staged_paths
# /git_staged_paths
EOF
  run pp_router_pick_lenses '{}' '' "$facts_file"
  [ "$status" -eq 0 ]
  picked_count=$(printf '%s' "$output" | grep -c '^.')
  # Expect 3 picks total (max), with UX_DESIGN and PRODUCT_BIZ replaced
  # by the next-ranked eligible: SECURITY, PERF_FINOPS (ENGINEERING was
  # already picked).
  [ "$picked_count" -eq 3 ]
  printf '%s' "$output" | grep -qxF 'ENGINEERING'
  printf '%s' "$output" | grep -qxF 'SECURITY'
  printf '%s' "$output" | grep -qxF 'PERF_FINOPS'
}

@test "Stage D router (gates ON, facts file missing): falls open (no crash)" {
  export PP_LENS_GATES_ACTIVE=1
  export PP_LENS_GATES_TELEMETRY=0
  export PP_LENS_IDS_AVAILABLE=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_FORCE_OUTPUT=$'UX_DESIGN\nENGINEERING\nSECURITY'
  export PP_ROUTER_ENABLE=1
  # Path that does not exist.
  run pp_router_pick_lenses '{}' '' "/nonexistent/$$/$RANDOM/facts.txt"
  [ "$status" -eq 0 ]
  # Eligibility evaluation gracefully degrades to "no path set" → since
  # PP_LENS_GATES_ACTIVE=1, all picks dropped. To avoid silent
  # dark-mode, the spec/Task 10 explicitly says fan-out runs smaller —
  # in the limit, output is empty. Test asserts NO crash and exit 0.
  true
}
