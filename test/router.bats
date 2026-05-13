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
        PP_LENS_IDS_AVAILABLE PP_EVAL_MODE PP_RANDOM_SEED
}

teardown() { rm -rf "$HOME"; }

# Helper: pass a newline-delimited registry via env (C5 fix).
_enable() {
  PP_LENS_IDS_AVAILABLE="$(printf '%s\n' "$@")"
  export PP_LENS_IDS_AVAILABLE
}

# ----- ENABLE=0 / EVAL_MODE bypass (v0.3 fallback) -----

@test "pick: PP_ROUTER_ENABLE=0 returns ALL enabled lens IDs" {
  _enable engineering security ux-design
  PP_ROUTER_ENABLE=0 run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.' )
  [ "$line_count" -eq 3 ]
  printf '%s' "$output" | grep -qF 'engineering'
  printf '%s' "$output" | grep -qF 'security'
  printf '%s' "$output" | grep -qF 'ux-design'
}

@test "pick: PP_EVAL_MODE=1 bypasses router and returns ALL enabled" {
  _enable engineering security
  PP_EVAL_MODE=1 PP_ROUTER_ENABLE=1 run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  line_count=$(printf '%s\n' "$output" | grep -c '^.' )
  [ "$line_count" -eq 2 ]
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

@test "pick: I1 — lowercases and trims router output before validation" {
  _enable engineering security
  PP_ROUTER_ENABLE=1 \
    PP_ROUTER_FORCE_OUTPUT=$'  Engineering   \nSECURITY ' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'engineering'
  printf '%s' "$output" | grep -qF 'security'
  # No capitalized version leaked through
  ! printf '%s' "$output" | grep -qF 'Engineering'
  ! printf '%s' "$output" | grep -qF 'SECURITY'
}

@test "pick: I6 — strict regex rejects markdown bullets / numbered lists" {
  _enable engineering security
  PP_ROUTER_ENABLE=1 \
    PP_ROUTER_FORCE_OUTPUT=$'- engineering\n1. security' \
    run pp_router_pick_lenses '' ''
  [ "$status" -eq 0 ]
  # Lines with leading punctuation should be filtered out before validation
  ! printf '%s' "$output" | grep -qE '^[-*0-9]'
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

@test "surprise: doesn't duplicate when injected lens already in picked set" {
  # If somehow not_picked contains a lens already in picked, dedupe.
  PP_ROUTER_SURPRISE_PROB=1.0 PP_RANDOM_SEED=42 \
    run pp_router_surprise_inject $'engineering' $'engineering\nsecurity'
  [ "$status" -eq 0 ]
  # 'engineering' should appear at most once
  count=$(printf '%s\n' "$output" | grep -c '^engineering$')
  [ "$count" -eq 1 ]
}
