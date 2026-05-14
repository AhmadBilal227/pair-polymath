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

# ========================================================
# Task 5: pp_retry_log_shadow append + rotation
# ========================================================

@test "log_shadow: writes JSONL line to retry-router-shadow.jsonl" {
  . "$PP_ROOT/lib/retry-router.sh"
  export PP_RETRY_ROUTER_SHADOW=1
  pp_retry_log_shadow '{"ts":"2026-05-14T00:00:00Z","lens":"ENG","drop_reason_class":"vague"}'
  [ -f "$PP_CACHE_DIR/retry-router-shadow.jsonl" ]
  [ "$(wc -l < "$PP_CACHE_DIR/retry-router-shadow.jsonl" | tr -d ' ')" = "1" ]
}

@test "log_shadow: silent when PP_RETRY_ROUTER_SHADOW=0 (default)" {
  . "$PP_ROOT/lib/retry-router.sh"
  unset PP_RETRY_ROUTER_SHADOW
  pp_retry_log_shadow '{"x":1}'
  [ ! -f "$PP_CACHE_DIR/retry-router-shadow.jsonl" ]
}

@test "log_shadow: rotates when file exceeds PP_LOG_MAX_BYTES" {
  . "$PP_ROOT/lib/retry-router.sh"
  export PP_RETRY_ROUTER_SHADOW=1
  export PP_LOG_MAX_BYTES=200
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    pp_retry_log_shadow "{\"i\":$_i,\"padding\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}"
  done
  [ -f "$PP_CACHE_DIR/retry-router-shadow.jsonl.1" ] \
    || [ "$(wc -c < "$PP_CACHE_DIR/retry-router-shadow.jsonl" | tr -d ' ')" -le 200 ]
}

@test "log_shadow: failure (bad dir) does not error — silent" {
  . "$PP_ROOT/lib/retry-router.sh"
  export PP_RETRY_ROUTER_SHADOW=1
  export PP_CACHE_DIR=/nonexistent/readonly/path
  run pp_retry_log_shadow '{"x":1}'
  [ "$status" -eq 0 ]
}

# ========================================================
# Task 6: pp_retry_canary_bucket sticky hash cohort
# ========================================================

@test "canary_bucket: same session_id → same bucket" {
  . "$PP_ROOT/lib/retry-router.sh"
  local _b1 _b2
  _b1=$(pp_retry_canary_bucket "session-abc-123")
  _b2=$(pp_retry_canary_bucket "session-abc-123")
  [ "$_b1" = "$_b2" ]
  [ "$_b1" -ge 0 ] && [ "$_b1" -le 99 ]
}

@test "canary_bucket: distribution over 1000 sessions ≈ uniform" {
  . "$PP_ROOT/lib/retry-router.sh"
  local _lt10=0 _i _b
  for _i in $(seq 1 1000); do
    _b=$(pp_retry_canary_bucket "session-$_i")
    [ "$_b" -lt 10 ] && _lt10=$((_lt10 + 1))
  done
  # Expect ~100 in <10 bucket; allow 60-140 (3σ-ish)
  [ "$_lt10" -ge 60 ] && [ "$_lt10" -le 140 ]
}

# ========================================================
# Task 7: pp_metrics_estimate_retry_usd preflight estimator
# ========================================================

@test "estimate_retry_usd: gpt-5 returns positive USD" {
  . "$PP_ROOT/lib/metrics.sh"
  local _est
  _est=$(pp_metrics_estimate_retry_usd gpt-5)
  [ -n "$_est" ]
  awk "BEGIN{exit !($_est > 0)}"
}

@test "estimate_retry_usd: gpt-5-mini < gpt-5" {
  . "$PP_ROOT/lib/metrics.sh"
  local _mini _big
  _mini=$(pp_metrics_estimate_retry_usd gpt-5-mini)
  _big=$(pp_metrics_estimate_retry_usd gpt-5)
  awk "BEGIN{exit !($_mini < $_big)}"
}

# ========================================================
# Task 10: pp_retry_hard_cap_preflight skip-on-budget
# ========================================================

@test "hard_cap: skip when accumulated + estimated > cap" {
  . "$PP_ROOT/lib/retry-router.sh"
  . "$PP_ROOT/lib/metrics.sh"
  local _sid=s-hardcap-1
  export PP_RETRY_HARD_CAP_ENABLE=1 PP_RETRY_USD_PER_CYCLE_HARD_CAP=0.005
  # Accumulate 0.004 in-flight; one gpt-5 retry (~$0.0049) would exceed 0.005.
  printf '0.004' > "$PP_CACHE_DIR/retry-cycle-spend-${_sid}.txt"
  run pp_retry_hard_cap_preflight "$_sid" gpt-5
  [ "$status" -ne 0 ]
}

@test "hard_cap: allow when accumulated + estimated <= cap" {
  . "$PP_ROOT/lib/retry-router.sh"
  . "$PP_ROOT/lib/metrics.sh"
  local _sid=s-hardcap-2
  export PP_RETRY_HARD_CAP_ENABLE=1 PP_RETRY_USD_PER_CYCLE_HARD_CAP=0.05
  printf '0.000' > "$PP_CACHE_DIR/retry-cycle-spend-${_sid}.txt"
  run pp_retry_hard_cap_preflight "$_sid" gpt-5
  [ "$status" -eq 0 ]
}

@test "hard_cap: no-op when PP_RETRY_HARD_CAP_ENABLE=0" {
  . "$PP_ROOT/lib/retry-router.sh"
  . "$PP_ROOT/lib/metrics.sh"
  export PP_RETRY_HARD_CAP_ENABLE=0
  run pp_retry_hard_cap_preflight "any" gpt-5
  [ "$status" -eq 0 ]
}

# ========================================================
# Task 12: Auto-rollback state machine (lib/auto-rollback.sh)
# ========================================================

@test "auto_rollback: no flag initially" {
  . "$PP_ROOT/lib/auto-rollback.sh"
  run pp_rollback_is_active
  [ "$status" -ne 0 ]
}

@test "auto_rollback: flag persists once set" {
  . "$PP_ROOT/lib/auto-rollback.sh"
  pp_rollback_engage 24
  run pp_rollback_is_active
  [ "$status" -eq 0 ]
  pp_rollback_clear
  run pp_rollback_is_active
  [ "$status" -ne 0 ]
}

@test "auto_rollback: backoff escalates on repeat" {
  . "$PP_ROOT/lib/auto-rollback.sh"
  pp_rollback_engage 24
  pp_rollback_clear
  # 2nd engage within 30d → repeat backoff
  local _hours
  _hours=$(pp_rollback_next_backoff_hours)
  [ "$_hours" = "72" ]
}

# ========================================================
# Task 15: Retry router integration in bin/statusline.sh
# ========================================================

@test "integration: shadow log writes when SHADOW=1 (smoke)" {
  # Minimal smoke — the integration site calls pp_retry_log_shadow with the
  # same SHADOW gating as standalone. Synthesize a payload and assert the
  # JSONL line lands.
  . "$PP_ROOT/lib/retry-router.sh"
  export PP_RETRY_ROUTER_SHADOW=1
  local _blob
  _blob=$(jq -nc \
    --arg ts "2026-05-14T00:00:00Z" \
    --arg sid "s-integration-1" \
    --arg lens "ENG" \
    --arg drc "vague" \
    --arg conf "low" \
    --arg shadow_model "gpt-5-mini" \
    --argjson canary_active 0 \
    '{ts:$ts,session:$sid,lens:$lens,drop_reason_class:$drc,confidence:$conf,shadow_model:$shadow_model,canary_active:$canary_active}')
  pp_retry_log_shadow "$_blob"
  [ -f "$PP_CACHE_DIR/retry-router-shadow.jsonl" ]
  jq -e '.drop_reason_class == "vague" and .canary_active == 0' \
    "$PP_CACHE_DIR/retry-router-shadow.jsonl" >/dev/null
}

@test "integration: statusline sources retry-router + auto-rollback libs" {
  # The integration MUST source both libs near the budget.sh source. Quick
  # static check — fail loudly if the import is accidentally dropped.
  grep -q 'lib/retry-router.sh' "$PP_ROOT/bin/statusline.sh"
  grep -q 'lib/auto-rollback.sh' "$PP_ROOT/bin/statusline.sh"
}

# ========================================================
# Task 17: polymath retry-router CLI subcommand
# ========================================================

@test "cli: polymath retry-router status prints current state" {
  run bash "$PP_ROOT/bin/polymath" retry-router status
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qE 'Retry router'
  printf '%s' "$output" | grep -qE 'Enabled:'
}

@test "cli: polymath retry-router clear-flag removes the flag file" {
  . "$PP_ROOT/lib/auto-rollback.sh"
  pp_rollback_engage 24
  pp_rollback_is_active
  run bash "$PP_ROOT/bin/polymath" retry-router clear-flag
  [ "$status" -eq 0 ]
  # Re-source to pick up cleared state; pp_rollback_is_active returns non-zero now.
  . "$PP_ROOT/lib/auto-rollback.sh"
  run pp_rollback_is_active
  [ "$status" -ne 0 ]
}

@test "cli: polymath retry-router shadow-summary empty-state hints SHADOW=1" {
  run bash "$PP_ROOT/bin/polymath" retry-router shadow-summary
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'PP_RETRY_ROUTER_SHADOW=1'
}

# ========================================================
# Task 18: Doctor check #19 — retry router health
# ========================================================

@test "doctor: check #19 retry-router-health appears in pp_doctor_run output" {
  # Doctor may exit non-zero if other checks (openai key, llm install) fail in
  # the hermetic test env; we only care that #19 surfaces.
  run bash "$PP_ROOT/bin/polymath" doctor
  printf '%s' "$output" | grep -qE 'retry router'
}
