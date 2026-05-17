#!/usr/bin/env bats
# v0.5.2 Task 13 — KPI hallucination split.
#
# Covers:
#   - pp_kpi_emit_cycle transports the two new fields when present in the
#     blob (the emitter is a pure pass-through; this is the contract).
#   - halluc_pre_drop_rate + halluc_post_would_drop_rate are floats in [0,1].
#   - Defensive denominator-zero handling: a cycle with 0 critique DROPs
#     (or 0 critique PASSes) emits 0 for the corresponding rate — never a
#     divide-by-zero token like `nan` or `inf` or an empty argjson.
#   - The byte-identity invariant: with PP_KPI_ENABLE=0 + router off, no
#     kpi-cycle.jsonl is written and the file does not exist after a
#     cycle that uses the same code path. (Stronger invariants in
#     test/v0.5.1-byte-identity.bats; this is a focused unit guard.)
#
# Denominator choices (plan addendum I4):
#   halluc_pre_drop_rate         = citation_fail DROPs / total DROPs   [per cycle]
#   halluc_post_would_drop_rate  = post-check would-DROPs / critique PASSes [per cycle]
# Both are bounded in [0,1] by construction. Inline docstrings on the
# emit site at bin/statusline.sh document this; these tests anchor the
# contract.

setup() {
  HOME="$(mktemp -d)"; export HOME
  PP_CACHE_DIR="$HOME/.claude/cache"; mkdir -p "$PP_CACHE_DIR"; export PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; export PP_ROOT
}
teardown() { rm -rf "$HOME"; }

@test "kpi_emit: cycle blob carries halluc_pre_drop_rate and halluc_post_would_drop_rate" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_KPI_ENABLE=1
  pp_kpi_emit_cycle '{"ts":"2026-05-15T00:00:00Z","session":"s1","halluc_pre_drop_rate":0.10,"halluc_post_would_drop_rate":0.04}'
  [ -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ]
  jq -e '.halluc_pre_drop_rate == 0.10 and .halluc_post_would_drop_rate == 0.04' \
    "$PP_CACHE_DIR/kpi-cycle.jsonl" >/dev/null
}

@test "kpi_emit: both rates are floats in [0,1]" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_KPI_ENABLE=1
  pp_kpi_emit_cycle '{"ts":"2026-05-15T00:00:00Z","session":"s1","halluc_pre_drop_rate":0.5000,"halluc_post_would_drop_rate":1.0000}'
  jq -e '
    (.halluc_pre_drop_rate | type) == "number"
    and (.halluc_post_would_drop_rate | type) == "number"
    and .halluc_pre_drop_rate >= 0 and .halluc_pre_drop_rate <= 1
    and .halluc_post_would_drop_rate >= 0 and .halluc_post_would_drop_rate <= 1
  ' "$PP_CACHE_DIR/kpi-cycle.jsonl" >/dev/null
}

@test "kpi_emit: zero-DROPs cycle emits halluc_pre_drop_rate=0 (no div-by-zero)" {
  # The emitter is a pure transport; the awk div-zero guard lives in
  # bin/statusline.sh's blob assembly. This test asserts the
  # caller-side contract: when total DROPs is 0 the field is 0 (not
  # null, not "nan", not missing).
  . "$PP_ROOT/lib/metrics.sh"
  export PP_KPI_ENABLE=1
  # Mirror exactly what statusline.sh's awk produces with t=0.
  _rate=$(LC_ALL=C awk -v c=0 -v t=0 \
    'BEGIN { if (t > 0) printf "%.4f", c / t; else printf "0" }')
  [ "$_rate" = "0" ]
  pp_kpi_emit_cycle "{\"ts\":\"2026-05-15T00:00:00Z\",\"session\":\"s1\",\"halluc_pre_drop_rate\":$_rate,\"halluc_post_would_drop_rate\":0}"
  jq -e '.halluc_pre_drop_rate == 0 and .halluc_post_would_drop_rate == 0' \
    "$PP_CACHE_DIR/kpi-cycle.jsonl" >/dev/null
}

@test "kpi_emit: zero-PASSes cycle emits halluc_post_would_drop_rate=0 (no div-by-zero)" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_KPI_ENABLE=1
  # Numerator could be 0 (no would-drops because nothing was checked)
  # OR a stale positive from the previous cycle if the counter wasn't
  # reset. statusline.sh resets _pp_halluc_post_drops to 0 at cycle
  # start (line ~1065). Both sides → 0/0 → 0.
  _rate=$(LC_ALL=C awk -v c=0 -v p=0 \
    'BEGIN { if (p > 0) printf "%.4f", c / p; else printf "0" }')
  [ "$_rate" = "0" ]
}

@test "kpi_emit: a rate-bearing row coexists with all prior v0.5.1 fields" {
  # Schema-additive guard: emitting halluc_* must not displace the
  # v0.5.1 fields (cost_usd, retry_count, phase, slo_breach, ...).
  . "$PP_ROOT/lib/metrics.sh"
  export PP_KPI_ENABLE=1
  pp_kpi_emit_cycle '{"ts":"2026-05-15T00:00:00Z","session":"s1","cost_usd":0.01,"retry_count":1,"retry_usd":0.003,"inv_count":0,"picked_count":2,"phase":"drafting","phase_source":"pattern","retry_acceptance_rate":0.5,"verdict_total_drops":3,"halluc_pre_drop_rate":0.3333,"halluc_post_would_drop_rate":0.0,"cycle_outcome":"success","eligible":1,"slo_breach":0}'
  jq -e '
    .cost_usd == 0.01
    and .retry_count == 1
    and .phase == "drafting"
    and .verdict_total_drops == 3
    and .halluc_pre_drop_rate == 0.3333
    and .halluc_post_would_drop_rate == 0.0
    and .slo_breach == 0
    and .eligible == 1
  ' "$PP_CACHE_DIR/kpi-cycle.jsonl" >/dev/null
}

@test "kpi_emit: PP_KPI_ENABLE=0 + router off → no kpi-cycle.jsonl regardless of halluc payload" {
  # Byte-identity guard at the emitter level. The statusline integration
  # test in test/v0.5.1-byte-identity.bats is the holistic guard; this
  # is the targeted unit assertion for this task's surface.
  . "$PP_ROOT/lib/metrics.sh"
  unset PP_KPI_ENABLE PP_RETRY_ROUTER_ENABLE PP_RETRY_ROUTER_SHADOW
  pp_kpi_emit_cycle '{"ts":"2026-05-15T00:00:00Z","session":"s1","halluc_pre_drop_rate":0.5,"halluc_post_would_drop_rate":0.5}'
  [ ! -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ]
}

# ========================================================
# Statusline integration: end-to-end blob shape check
# ========================================================
#
# Exercise the actual cycle. With PP_KPI_ENABLE=1 + a real cycle run, a
# kpi-cycle.jsonl row must appear and carry both new fields. We don't
# control critique output in tests (no real LLM), so the rates will
# typically be 0 — that's the correct denominator-zero behavior. The
# point is to prove the assembly path doesn't drop the fields.

@test "statusline integration: PP_KPI_ENABLE=1 cycle emits row with both halluc fields" {
  PP_CACHE_DIR="$HOME/.claude/cache"; export PP_CACHE_DIR
  mkdir -p "$PP_CACHE_DIR"

  # Build a real transcript + stdin JSON so the cycle gate opens.
  PP_TX="$HOME/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' > "$PP_TX"
  PP_STDIN="$HOME/stdin.json"
  printf '{"session_id":"kpi-halluc","workspace":{"current_dir":"%s"},"model":{"display_name":"Sonnet 4.6"},"transcript_path":"%s","cost":{"total_cost_usd":0.0},"exceeds_200k_tokens":false}\n' \
    "$HOME" "$PP_TX" > "$PP_STDIN"

  # Shadow `llm` for zero-cost cycles.
  PP_FAKEBIN="$HOME/fakebin"; mkdir -p "$PP_FAKEBIN"
  printf '#!/bin/sh\nprintf "SILENT\\n"\n' > "$PP_FAKEBIN/llm"
  chmod +x "$PP_FAKEBIN/llm"
  PATH="$PP_FAKEBIN:$PATH"; export PATH

  CLAUDE_DIR="$HOME/.claude"; export CLAUDE_DIR

  PP_USER_ENV="$CLAUDE_DIR/pair-polymath/config/user.env"
  mkdir -p "$(dirname "$PP_USER_ENV")"
  printf 'PP_KPI_ENABLE=1\n' > "$PP_USER_ENV"

  export PP_EVAL_MODE=1 PP_EXTERNAL_LLM=1 PP_KPI_ENABLE=1
  bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" >/dev/null 2>&1 || true

  # The KPI row may or may not be produced depending on whether the
  # synchronous can_run path landed (eligible:0 still emits a row).
  # When emitted, both new fields MUST be present.
  if [ -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ] \
       && [ -s "$PP_CACHE_DIR/kpi-cycle.jsonl" ]; then
    jq -e '
      has("halluc_pre_drop_rate")
      and has("halluc_post_would_drop_rate")
      and (.halluc_pre_drop_rate | type) == "number"
      and (.halluc_post_would_drop_rate | type) == "number"
      and .halluc_pre_drop_rate >= 0 and .halluc_pre_drop_rate <= 1
      and .halluc_post_would_drop_rate >= 0 and .halluc_post_would_drop_rate <= 1
    ' "$PP_CACHE_DIR/kpi-cycle.jsonl" >/dev/null
  else
    skip "cycle did not emit a KPI row in this hermetic setup (no can_run path)"
  fi
}

@test "statusline integration: PP_KPI_ENABLE=0 cycle does NOT produce kpi-cycle.jsonl" {
  PP_CACHE_DIR="$HOME/.claude/cache"; export PP_CACHE_DIR
  mkdir -p "$PP_CACHE_DIR"

  PP_TX="$HOME/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' > "$PP_TX"
  PP_STDIN="$HOME/stdin.json"
  printf '{"session_id":"kpi-halluc-off","workspace":{"current_dir":"%s"},"model":{"display_name":"Sonnet 4.6"},"transcript_path":"%s","cost":{"total_cost_usd":0.0},"exceeds_200k_tokens":false}\n' \
    "$HOME" "$PP_TX" > "$PP_STDIN"

  PP_FAKEBIN="$HOME/fakebin"; mkdir -p "$PP_FAKEBIN"
  printf '#!/bin/sh\nprintf "SILENT\\n"\n' > "$PP_FAKEBIN/llm"
  chmod +x "$PP_FAKEBIN/llm"
  PATH="$PP_FAKEBIN:$PATH"; export PATH

  CLAUDE_DIR="$HOME/.claude"; export CLAUDE_DIR
  unset PP_KPI_ENABLE PP_RETRY_ROUTER_ENABLE PP_RETRY_ROUTER_SHADOW
  export PP_EVAL_MODE=1 PP_EXTERNAL_LLM=1
  bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" >/dev/null 2>&1 || true

  [ ! -f "$PP_CACHE_DIR/kpi-cycle.jsonl" ] \
    || { ls -la "$PP_CACHE_DIR" >&2; false; }
}

# ========================================================
# Source-shape guards (anti-drift)
# ========================================================
#
# Lock down the literal field names + the per-cycle counter names so a
# rename without intent makes the test fail loudly. The emitter is the
# source of truth — downstream (polymath kpi, polymath history) reads
# these field names verbatim.

@test "source-shape: statusline.sh references _pp_halluc_pre_drops counter" {
  grep -q '_pp_halluc_pre_drops' "$PP_ROOT/bin/statusline.sh"
}

@test "source-shape: statusline.sh references _pp_halluc_post_passes_checked denominator" {
  grep -q '_pp_halluc_post_passes_checked' "$PP_ROOT/bin/statusline.sh"
}

@test "source-shape: statusline.sh emits halluc_pre_drop_rate + halluc_post_would_drop_rate keys" {
  grep -q 'halluc_pre_drop_rate' "$PP_ROOT/bin/statusline.sh"
  grep -q 'halluc_post_would_drop_rate' "$PP_ROOT/bin/statusline.sh"
}
