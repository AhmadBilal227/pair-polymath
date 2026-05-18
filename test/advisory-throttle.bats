#!/usr/bin/env bats
# UserPromptSubmit advisory throttle/grouping.

setup() {
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR/config"
}

teardown() {
  rm -rf "$HOME"
}

_seed_obs() {
  local sid="$1" lens="$2" line="$3"
  printf '%s\n' "$line" > "$PP_CACHE_DIR/cc-monitor-${sid}-${lens}.txt"
}

_run_hook() {
  local sid="$1"
  run bash -c "printf '{\"session_id\":\"$sid\"}' | bash '$PP_ROOT/hooks/inject-monitor-insight.sh'"
}

@test "advisory throttle: injects at most 3 ranked observations and dynamic copy" {
  sid="thr-max"
  _seed_obs "$sid" ENGINEERING 'ENG: harden parser with grounded file|||Fix lib/oar.sh by running pp_oar_label_pending() tests before release.'
  _seed_obs "$sid" SECURITY 'SEC: protect token handling grounded|||Fix lib/security.sh so pp_secret_scan() catches leaked credentials before commit.'
  _seed_obs "$sid" PERF_FINOPS 'OPS: cap cost regression grounded|||Measure lib/metrics.sh pp_metrics_estimate_retry_usd() before raising retry limits.'
  _seed_obs "$sid" PRODUCT_BIZ 'PROD: decide rollout gate grounded|||Review docs/release.md and decide whether the bootstrap gate blocks launch.'
  _seed_obs "$sid" STRATEGIC_FOUNDER 'STRAT: inspect roadmap risk grounded|||Review docs/roadmap.md and choose the next operator-facing release slice.'
  _run_hook "$sid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKGROUND ADVISORY"* ]]
  [[ "$output" != *"Seven specialized lens agents"* ]]
  [[ "$output" == *"Pair Polymath surfaced 3 ranked advisory note"* ]]
  count=$(printf '%s\n' "$output" | grep -Ec '^(ENGINEERING|SECURITY|PERF_FINOPS|PRODUCT_BIZ|STRATEGIC_FOUNDER): ')
  [ "$count" -eq 3 ]
  [ -s "$PP_CACHE_DIR/advisory-throttle.jsonl" ]
  jq -e 'select(.reason == "over_limit")' "$PP_CACHE_DIR/advisory-throttle.jsonl" >/dev/null
}

@test "advisory throttle: repeated non-protected topic cools down" {
  sid="thr-cool"
  _seed_obs "$sid" ENGINEERING 'ENG: repeat grounded parser topic|||Fix lib/repeat.sh by running pp_repeat_check() before merging this patch.'
  _run_hook "$sid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKGROUND ADVISORY"* ]]
  _run_hook "$sid"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jq -e 'select(.reason == "cooldown" or .reason == "lens_idempotency")' "$PP_CACHE_DIR/advisory-throttle.jsonl" >/dev/null
}

@test "advisory throttle: protected classes require grounding before injection" {
  sid="thr-protected"
  _seed_obs "$sid" SECURITY 'SEC: vague token issue without cite|||Maybe there is some secret risk somewhere but no concrete file or symbol is named.'
  _run_hook "$sid"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jq -e 'select(.reason == "protected_without_grounding" and .protected == true)' \
    "$PP_CACHE_DIR/advisory-throttle.jsonl" >/dev/null
}

@test "advisory throttle: same topic from multiple lenses is grouped as quorum" {
  sid="thr-quorum"
  line='ENG: shared grounded release topic|||Fix lib/shared.sh by running pp_shared_check() before saying the release is clean.'
  _seed_obs "$sid" ENGINEERING "$line"
  _seed_obs "$sid" PRODUCT_BIZ "$line"
  _run_hook "$sid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"QUORUM"* ]]
  body_count=$(printf '%s\n' "$output" | grep -c 'Fix lib/shared.sh')
  [ "$body_count" -eq 1 ]
}
