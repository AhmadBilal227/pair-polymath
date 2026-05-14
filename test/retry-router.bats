#!/usr/bin/env bats
# v0.5.1 Tier 0 — Cost-aware retry router.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}
teardown() { rm -rf "$HOME"; }

@test "env: PP_RETRY_ROUTER_ENABLE default is 0" {
  unset PP_RETRY_ROUTER_ENABLE
  # shellcheck source=../config/default.env
  . "$PP_ROOT/config/default.env"
  [ "${PP_RETRY_ROUTER_ENABLE:-NOTSET}" = "0" ]
}

@test "env: PP_RETRY_ROUTER_SHADOW default is 0" {
  unset PP_RETRY_ROUTER_SHADOW
  . "$PP_ROOT/config/default.env"
  [ "${PP_RETRY_ROUTER_SHADOW:-NOTSET}" = "0" ]
}

@test "env: PP_KPI_ENABLE default is 0" {
  unset PP_KPI_ENABLE
  . "$PP_ROOT/config/default.env"
  [ "${PP_KPI_ENABLE:-NOTSET}" = "0" ]
}

@test "env: PP_ESCALATION_STREAK_THRESHOLD default is 3" {
  unset PP_ESCALATION_STREAK_THRESHOLD
  . "$PP_ROOT/config/default.env"
  [ "${PP_ESCALATION_STREAK_THRESHOLD:-NOTSET}" = "3" ]
}

# ========================================================
# Task 2: pp_retry_classify_reason taxonomy
# ========================================================

@test "classify: citation_fail when reason mentions citation" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_classify_reason 'citation invalid — path not in allowlist')" = "citation_fail" ]
  [ "$(pp_retry_classify_reason 'hallucinated symbol')" = "citation_fail" ]
  [ "$(pp_retry_classify_reason 'fabricated path')" = "citation_fail" ]
}

@test "classify: stale when reason mentions already-fixed" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_classify_reason 'already addressed in cycle 5')" = "stale" ]
  [ "$(pp_retry_classify_reason 'outdated — fixed last commit')" = "stale" ]
}

@test "classify: vague when no actionable step" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_classify_reason 'vague — investigate further')" = "vague" ]
  [ "$(pp_retry_classify_reason 'no actionable next step')" = "vague" ]
}

@test "classify: redundant when overlapping with prior lens" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_classify_reason 'redundant — UX already raised this')" = "redundant" ]
  [ "$(pp_retry_classify_reason 'duplicate of lens3 finding')" = "redundant" ]
}

@test "classify: format when output schema broken" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_classify_reason 'malformed — missing pipe delimiter')" = "format" ]
  [ "$(pp_retry_classify_reason 'invalid schema')" = "format" ]
}

@test "classify: unknown when reason text doesn't match any class" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_classify_reason 'something weird happened')" = "unknown" ]
  [ "$(pp_retry_classify_reason '')" = "unknown" ]
}

# ========================================================
# Task 3: pp_retry_confidence high/low gate
# ========================================================

@test "confidence: citation_fail with non-empty allowlist + body>=80 → high" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_confidence citation_fail 3 2 100 1 1)" = "high" ]
}

@test "confidence: citation_fail with empty allowlist → low (no contrast signal)" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_confidence citation_fail 0 0 100 1 1)" = "low" ]
}

@test "confidence: citation_fail with concurrent_drops>2 → low (cycle storm)" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_confidence citation_fail 3 2 100 1 4)" = "low" ]
}

@test "confidence: vague always → low" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_confidence vague 5 5 200 0 0)" = "low" ]
}

@test "confidence: format always → low (cheap to retry on mini)" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_confidence format 3 3 200 1 1)" = "low" ]
}

@test "confidence: stale always → low" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_confidence stale 3 3 100 1 1)" = "low" ]
}

@test "confidence: short body (<80) → low even on citation_fail" {
  . "$PP_ROOT/lib/retry-router.sh"
  [ "$(pp_retry_confidence citation_fail 3 2 40 1 1)" = "low" ]
}

# ========================================================
# Task 4: pp_retry_select_model with PP_RETRY_MODEL escape hatch
# ========================================================

@test "select_model: high → PP_RETRY_MODEL_HIGH" {
  . "$PP_ROOT/lib/retry-router.sh"
  unset PP_RETRY_MODEL
  export PP_RETRY_MODEL_HIGH=gpt-5-custom PP_RETRY_MODEL_LOW=gpt-5-mini-custom
  [ "$(pp_retry_select_model high)" = "gpt-5-custom" ]
}

@test "select_model: low → PP_RETRY_MODEL_LOW" {
  . "$PP_ROOT/lib/retry-router.sh"
  unset PP_RETRY_MODEL
  export PP_RETRY_MODEL_HIGH=gpt-5-custom PP_RETRY_MODEL_LOW=gpt-5-mini-custom
  [ "$(pp_retry_select_model low)" = "gpt-5-mini-custom" ]
}

@test "select_model: PP_RETRY_MODEL pin overrides both tiers (escape hatch)" {
  . "$PP_ROOT/lib/retry-router.sh"
  export PP_RETRY_MODEL=user-pinned-model
  export PP_RETRY_MODEL_HIGH=gpt-5 PP_RETRY_MODEL_LOW=gpt-5-mini
  [ "$(pp_retry_select_model high)" = "user-pinned-model" ]
}
