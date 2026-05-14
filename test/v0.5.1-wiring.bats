#!/usr/bin/env bats
# v0.5.1 Tier-0 INTEGRATION WIRING tests.
#
# Round-1 of the 5-way review found the branch built every primitive
# (528 unit tests green) but never wired them into the cycle — "ships the
# dashboard but not the meter." These tests prove the WIRING, not the
# primitives:
#   B1 — bin/statusline.sh actually calls pp_kpi_emit_cycle at cycle-end
#   B2 — pp_rollback_check_and_engage actually engages on synthetic breach
#   B3 — retry-cycle-spend file is reset at cycle start
#   B4 — pp_kpi_compute_p95 matches a hand-computed p95
#   I6 — shadow-summary group_by works on this jq (regression guard)

setup() {
  HOME="$(mktemp -d)"; export HOME
  CLAUDE_DIR="$HOME/.claude"; export CLAUDE_DIR
  PP_CACHE_DIR="$CLAUDE_DIR/cache"; mkdir -p "$PP_CACHE_DIR"; export PP_CACHE_DIR
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"; mkdir -p "$PP_STATE_DIR"; export PP_STATE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; export PP_ROOT

  # Build a real transcript + stdin JSON so the statusline cycle gate
  # (which checks [ -f "$transcript_path" ]) actually opens. PP_EVAL_MODE=1
  # forces the idle/interval gates open AND runs the cycle synchronously so
  # the cache files exist when the test reads them.
  PP_TX="$HOME/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' > "$PP_TX"
  PP_STDIN="$HOME/stdin.json"
  printf '{"session_id":"wire-test","workspace":{"current_dir":"%s"},"model":{"display_name":"Sonnet 4.6"},"transcript_path":"%s","cost":{"total_cost_usd":0.0},"exceeds_200k_tokens":false}\n' \
    "$HOME" "$PP_TX" > "$PP_STDIN"

  # Hermetic + zero-cost: shadow the real `llm` CLI with a stub that always
  # prints SILENT. This keeps can_run=1 (so the cycle body runs end-to-end,
  # including the B1/B2/B3 wiring) without making a real paid API call. The
  # stub dir goes first on PATH; everything else (jq, date, ...) still
  # resolves normally.
  PP_FAKEBIN="$HOME/fakebin"; mkdir -p "$PP_FAKEBIN"
  printf '#!/bin/sh\nprintf "SILENT\\n"\n' > "$PP_FAKEBIN/llm"
  chmod +x "$PP_FAKEBIN/llm"
  PATH="$PP_FAKEBIN:$PATH"; export PATH

  # statusline.sh sources lib/config.sh, which sources config/default.env
  # (where every PP_RETRY_ROUTER_* flag is hard-set to 0) THEN user.env.
  # So env-var exports get clobbered — flags must be written to user.env,
  # the same path real operators use.
  PP_USER_ENV="$CLAUDE_DIR/pair-polymath/config/user.env"
  mkdir -p "$(dirname "$PP_USER_ENV")"
  export PP_TX PP_STDIN PP_FAKEBIN PP_USER_ENV
}
teardown() { rm -rf "$HOME"; }

# ========================================================
# B1 — statusline actually emits kpi-cycle.jsonl
# ========================================================

@test "B1 wiring: statusline emits a kpi-cycle.jsonl line with the required schema" {
  # SHADOW=1 auto-enables the KPI emitter (router needs the data source).
  printf 'PP_RETRY_ROUTER_SHADOW=1\n' > "$PP_USER_ENV"
  export PP_EVAL_MODE=1
  export PP_EXTERNAL_LLM=1
  # No `llm` binary on PATH → can_run=0, no real LLM calls, but the B1
  # cycle-end block still runs and must emit the KPI row.
  bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" >/dev/null 2>&1 || true
  [ -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ]
  [ "$(wc -l < "$PP_CACHE_DIR/kpi-cycle.jsonl" | tr -d ' ')" -ge 1 ]
  # Every spec Section-L field must be present on the emitted line.
  run jq -e '
    has("ts") and has("session") and has("cost_usd") and has("retry_count")
    and has("retry_usd") and has("inv_count") and has("picked_count")
    and has("phase") and has("phase_source") and has("retry_acceptance_rate")
    and has("verdict_total_drops") and has("cycle_outcome") and has("slo_breach")
  ' "$PP_CACHE_DIR/kpi-cycle.jsonl"
  [ "$status" -eq 0 ]
}

@test "B1 wiring: NO kpi-cycle.jsonl when all router flags are off (byte-identity safe)" {
  unset PP_RETRY_ROUTER_SHADOW PP_RETRY_ROUTER_ENABLE PP_KPI_ENABLE
  export PP_EVAL_MODE=1
  export PP_EXTERNAL_LLM=1
  bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" >/dev/null 2>&1 || true
  [ ! -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ]
}

# ========================================================
# B2 — auto-rollback actually engages on synthetic breach data
# ========================================================

@test "B2 wiring: pp_rollback_check_and_engage engages flag on 25-cycle p95 breach" {
  . "$PP_ROOT/lib/metrics.sh"
  . "$PP_ROOT/lib/auto-rollback.sh"
  export PP_RETRY_SLO_MIN_SAMPLES=20
  export PP_RETRY_SLO_P95_CAP_USD=0.030
  export PP_RETRY_SLO_WINDOW_HOURS=24
  unset PP_RETRY_MODEL  # not user-pinned → eligible
  local _ts _i
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # 25 cycles, every retry_usd well above the 0.030 cap.
  for _i in $(seq 1 25); do
    printf '{"ts":"%s","session":"s","retry_usd":0.090,"cost_usd":0.1}\n' "$_ts" \
      >> "$PP_CACHE_DIR/kpi-cycle.jsonl"
  done
  if pp_rollback_is_active; then false; fi   # not engaged yet
  pp_rollback_check_and_engage
  pp_rollback_is_active     # flag now ACTIVE
}

@test "B2 wiring: pp_rollback_check_and_engage does NOT engage below min-samples" {
  . "$PP_ROOT/lib/metrics.sh"
  . "$PP_ROOT/lib/auto-rollback.sh"
  export PP_RETRY_SLO_MIN_SAMPLES=20
  export PP_RETRY_SLO_P95_CAP_USD=0.030
  unset PP_RETRY_MODEL
  local _ts _i
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for _i in $(seq 1 5); do  # only 5 cycles — under the 20 floor
    printf '{"ts":"%s","session":"s","retry_usd":0.500}\n' "$_ts" \
      >> "$PP_CACHE_DIR/kpi-cycle.jsonl"
  done
  pp_rollback_check_and_engage
  if pp_rollback_is_active; then false; fi   # sparse data → no SLO eval → no engage
}

@test "B2 wiring: pp_rollback_check_and_engage does NOT engage when p95 within cap" {
  . "$PP_ROOT/lib/metrics.sh"
  . "$PP_ROOT/lib/auto-rollback.sh"
  export PP_RETRY_SLO_MIN_SAMPLES=20
  export PP_RETRY_SLO_P95_CAP_USD=0.030
  unset PP_RETRY_MODEL
  local _ts _i
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for _i in $(seq 1 25); do  # 25 cycles, all cheap
    printf '{"ts":"%s","session":"s","retry_usd":0.001}\n' "$_ts" \
      >> "$PP_CACHE_DIR/kpi-cycle.jsonl"
  done
  pp_rollback_check_and_engage
  if pp_rollback_is_active; then false; fi
}

@test "B2 wiring: user-pinned PP_RETRY_MODEL excludes the run from SLO eval" {
  . "$PP_ROOT/lib/metrics.sh"
  . "$PP_ROOT/lib/auto-rollback.sh"
  export PP_RETRY_SLO_MIN_SAMPLES=20
  export PP_RETRY_SLO_P95_CAP_USD=0.030
  export PP_RETRY_MODEL=gpt-5   # escape hatch → ineligible
  local _ts _i
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for _i in $(seq 1 25); do
    printf '{"ts":"%s","session":"s","retry_usd":0.500}\n' "$_ts" \
      >> "$PP_CACHE_DIR/kpi-cycle.jsonl"
  done
  pp_rollback_check_and_engage
  if pp_rollback_is_active; then false; fi   # pinned model → never engages
}

# ========================================================
# B3 — retry-cycle-spend file reset at cycle start
# ========================================================

@test "B3 wiring: statusline resets retry-cycle-spend file at cycle start" {
  export PP_EVAL_MODE=1
  export PP_EXTERNAL_LLM=1
  # Pre-seed a stale spend file from a 'previous cycle' that hit the cap.
  printf '0.049000\n' > "$PP_CACHE_DIR/retry-cycle-spend-wire-test.txt"
  bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" >/dev/null 2>&1 || true
  # After a cycle, the stale file must be gone (reset to a clean slate).
  [ ! -f "$PP_CACHE_DIR/retry-cycle-spend-wire-test.txt" ]
}

# ========================================================
# B4 — pp_kpi_compute_p95 matches a hand-computed p95
# ========================================================

@test "B4: pp_kpi_compute_p95 matches hand-computed nearest-rank p95" {
  . "$PP_ROOT/lib/metrics.sh"
  local _ts _i
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Dataset: retry_usd = 1..20. Nearest-rank p95 = ceil(0.95*20)=19th value = 19.
  for _i in $(seq 1 20); do
    printf '{"ts":"%s","session":"s","retry_usd":%d}\n' "$_ts" "$_i" \
      >> "$PP_CACHE_DIR/kpi-cycle.jsonl"
  done
  run pp_kpi_compute_p95 retry_usd 24
  [ "$status" -eq 0 ]
  # awk prints %.6f → "19.000000"
  [ "$(printf '%s' "$output" | cut -d. -f1)" = "19" ]
}

@test "B4: pp_kpi_compute_p95 includes the rotated .1 file" {
  . "$PP_ROOT/lib/metrics.sh"
  local _ts _i
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Older half in the rotated file, newer half in the live file.
  for _i in $(seq 1 10); do
    printf '{"ts":"%s","session":"s","retry_usd":%d}\n' "$_ts" "$_i" \
      >> "$PP_CACHE_DIR/kpi-cycle.jsonl.1"
  done
  for _i in $(seq 11 20); do
    printf '{"ts":"%s","session":"s","retry_usd":%d}\n' "$_ts" "$_i" \
      >> "$PP_CACHE_DIR/kpi-cycle.jsonl"
  done
  run pp_kpi_compute_p95 retry_usd 24
  # Union of 1..20 → p95 still 19. If .1 were ignored we'd get a wrong answer.
  [ "$(printf '%s' "$output" | cut -d. -f1)" = "19" ]
}

@test "B4: pp_kpi_compute_p95 honors the time window (old rows excluded)" {
  . "$PP_ROOT/lib/metrics.sh"
  local _old _new _i
  _old="2000-01-01T00:00:00Z"
  _new=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # 20 ancient rows with huge values — must be excluded by the 24h window.
  for _i in $(seq 1 20); do
    printf '{"ts":"%s","session":"s","retry_usd":999}\n' "$_old" \
      >> "$PP_CACHE_DIR/kpi-cycle.jsonl"
  done
  # 3 fresh small rows.
  for _i in 1 2 3; do
    printf '{"ts":"%s","session":"s","retry_usd":2}\n' "$_new" \
      >> "$PP_CACHE_DIR/kpi-cycle.jsonl"
  done
  run pp_kpi_compute_p95 retry_usd 24
  # Only the 3 fresh rows (all =2) are in-window → p95 = 2, not 999.
  [ "$(printf '%s' "$output" | cut -d. -f1)" = "2" ]
}

@test "B4: pp_kpi_compute_p95 prints 0 on empty dataset (fail-open)" {
  . "$PP_ROOT/lib/metrics.sh"
  run pp_kpi_compute_p95 retry_usd 24
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | cut -d. -f1)" = "0" ]
}

# ========================================================
# I3 — shared rotation helper is race-locked + DRY
# ========================================================

@test "I3: _pp_rotate_jsonl is the single shared rotation helper, mkdir-locked" {
  . "$PP_ROOT/lib/metrics.sh"
  # Helper exists and is used by BOTH emitters.
  command -v _pp_rotate_jsonl >/dev/null
  grep -q '_pp_rotate_jsonl' "$PP_ROOT/lib/metrics.sh"
  grep -q '_pp_rotate_jsonl' "$PP_ROOT/lib/retry-router.sh"
  # Rotation actually happens at the size threshold.
  local _f="$PP_CACHE_DIR/rot.jsonl"
  head -c 200 /dev/zero | tr '\0' 'x' > "$_f"
  _pp_rotate_jsonl "$_f" 100
  [ -f "${_f}.1" ]
  [ ! -f "$_f" ]
}

# ========================================================
# I6 — shadow-summary group_by regression guard
# ========================================================

@test "I6: polymath retry-router shadow-summary group_by produces correct counts" {
  # jq 1.7+ sorts internally for group_by; this regression test guards that
  # assumption (the v0.5.0 Phase-3 round-2 review verification approach).
  printf '%s\n' \
    '{"drop_reason_class":"vague"}' \
    '{"drop_reason_class":"citation_fail"}' \
    '{"drop_reason_class":"vague"}' \
    '{"drop_reason_class":"citation_fail"}' \
    '{"drop_reason_class":"vague"}' \
    > "$PP_CACHE_DIR/retry-router-shadow.jsonl"
  run bash "$PP_ROOT/bin/polymath" retry-router shadow-summary
  [ "$status" -eq 0 ]
  # vague:3, citation_fail:2 — group_by must NOT miscount despite interleaving.
  run bash -c "bash '$PP_ROOT/bin/polymath' retry-router shadow-summary \
    | jq -e 'map(select(.class==\"vague\"))[0].count == 3
             and map(select(.class==\"citation_fail\"))[0].count == 2'"
  [ "$status" -eq 0 ]
}
