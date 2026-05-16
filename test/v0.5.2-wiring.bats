#!/usr/bin/env bats
# v0.5.2 INTEGRATION WIRING tests.
#
# Round-N of the v0.5.1 review found the danger: build every primitive but
# never wire them. These tests prove the WIRING from primitive → cycle, not
# the primitives themselves (those are in test/oar-labeler.bats and
# test/hallucination-gate.bats).
#
# Task 11 (this file): bin/statusline.sh actually invokes pp_oar_label_pending
#   when PP_OAR_ENABLE=1; does NOT touch oar-labeled.jsonl when 0; preserves
#   v0.5.1 byte-identity STDOUT on the off path.

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
  printf '{"session_id":"wire-oar","workspace":{"current_dir":"%s"},"model":{"display_name":"Sonnet 4.6"},"transcript_path":"%s","cost":{"total_cost_usd":0.0},"exceeds_200k_tokens":false}\n' \
    "$HOME" "$PP_TX" > "$PP_STDIN"

  # Hermetic + zero-cost: shadow `llm` so can_run=1 but no real API calls.
  PP_FAKEBIN="$HOME/fakebin"; mkdir -p "$PP_FAKEBIN"
  printf '#!/bin/sh\nprintf "SILENT\\n"\n' > "$PP_FAKEBIN/llm"
  chmod +x "$PP_FAKEBIN/llm"
  PATH="$PP_FAKEBIN:$PATH"; export PATH

  # config/default.env hard-sets PP_OAR_ENABLE=0 (per v0.5.1 byte-identity
  # safety). Tests that need it on must write user.env, the same path real
  # operators use.
  PP_USER_ENV="$CLAUDE_DIR/pair-polymath/config/user.env"
  mkdir -p "$(dirname "$PP_USER_ENV")"
  export PP_TX PP_STDIN PP_FAKEBIN PP_USER_ENV
}
teardown() { rm -rf "$HOME"; }

# ========================================================
# Task 11 — pp_oar_label_pending is wired into the cycle
# ========================================================

@test "T11 wiring: PP_OAR_ENABLE=0 → no oar-labeled.jsonl produced (byte-identity safe)" {
  # Even with a pending row sitting in cache, the cycle must NOT touch it
  # when the gating flag is off. This is the v0.5.1 byte-identity contract.
  jq -nc '{session_id:"wire-oar",lens:"ENG",hash:"hx",
          inject_ts:"2026-05-15T00:00:00Z",scan_at_epoch:1,
          attempts:0,status:"pending",cited_paths:[],cited_symbols:[]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  unset PP_OAR_ENABLE
  export PP_EVAL_MODE=1 PP_EXTERNAL_LLM=1
  bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" >/dev/null 2>&1 || true
  # The labeler's side-effect file must NOT exist.
  [ ! -f "$PP_CACHE_DIR/oar-labeled.jsonl" ]
  # Pending row must still be there — unprocessed.
  [ -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
  [ -s "$PP_CACHE_DIR/oar-pending.jsonl" ]
}

@test "T11 wiring: PP_OAR_ENABLE=1 + pending row → labeler runs (oar-labeled.jsonl or oar-stuck.jsonl emerges)" {
  # End-to-end smoke: synthesize a pending row that's due, run a statusline
  # cycle with PP_OAR_ENABLE=1, assert the labeler actually processed it.
  # We allow EITHER outcome (labeled OR stuck) because the synthetic row's
  # transcript-tail is empty → most detectors return "ignored", which is
  # still a labeled outcome.
  printf 'PP_OAR_ENABLE=1\n' > "$PP_USER_ENV"
  # Due row: scan_at_epoch in the past so the FIFO snapshot picks it up.
  jq -nc --arg ts "2026-05-15T00:00:00Z" \
    '{session_id:"wire-oar",lens:"ENG",hash:"hy",
      inject_ts:$ts,scan_at_epoch:1,
      attempts:0,status:"pending",cited_paths:[],cited_symbols:[]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  export PP_EVAL_MODE=1 PP_EXTERNAL_LLM=1
  bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" >/dev/null 2>&1 || true
  # The cycle backgrounds the labeler — give it a beat to land. Inside
  # eval mode the outer cycle waits, but the OAR subshell is fire-and-forget
  # so we poll briefly.
  # GPT-review #8: extend poll window from 5s to 17s (matches the labeler's
  # 15s watchdog + 1s SIGTERM-grace + 1s buffer). 5s could flake on slow CI
  # hosts where the labeler takes longer than expected.
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
    [ -f "$PP_CACHE_DIR/oar-labeled.jsonl" ] && break
    [ -f "$PP_CACHE_DIR/oar-stuck.jsonl" ] && break
    sleep 1
  done
  # At least ONE side-effect file must exist (labeler ran).
  [ -f "$PP_CACHE_DIR/oar-labeled.jsonl" ] \
    || [ -f "$PP_CACHE_DIR/oar-stuck.jsonl" ] \
    || {
      # Pending may have been kept (not yet due) — check the pending file
      # was at least re-written (FIFO snapshot reshuffles by scan_at_epoch).
      # If neither output file nor change is visible, fail with diagnostics.
      printf 'Cache dir contents:\n' >&2
      ls -la "$PP_CACHE_DIR" >&2
      false
    }
}

@test "T11 wiring: PP_OAR_ENABLE=1 + NO pending file → statusline does not error" {
  # Defensive: with the flag on but no oar-pending.jsonl, the labeler must
  # short-circuit cleanly and the cycle must complete with exit 0.
  printf 'PP_OAR_ENABLE=1\n' > "$PP_USER_ENV"
  [ ! -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
  export PP_EVAL_MODE=1 PP_EXTERNAL_LLM=1
  run bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN"
  [ "$status" -eq 0 ]
  # No pending → no labeled output either.
  [ ! -f "$PP_CACHE_DIR/oar-labeled.jsonl" ]
}

@test "T11 wiring: PP_OAR_ENABLE=0 keeps STDOUT byte-identical to OAR-off run" {
  # Stronger invariant: STDOUT must not differ between "OAR-off, no pending"
  # and "OAR-off, pending file present" — the pending file is purely a
  # state-cache and never feeds into the render.
  unset PP_OAR_ENABLE
  export PP_EVAL_MODE=0 PP_EXTERNAL_LLM=1
  local _stdout_no_pending _stdout_with_pending
  _stdout_no_pending=$(bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" 2>/dev/null)
  jq -nc '{session_id:"x",lens:"ENG",hash:"h",
          inject_ts:"2026-05-15T00:00:00Z",scan_at_epoch:1,
          attempts:0,status:"pending",cited_paths:[],cited_symbols:[]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  _stdout_with_pending=$(bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" 2>/dev/null)
  # Both invocations include the leading tick emoji which can rotate by the
  # `date +%s` parity. Strip it before compare — same normalizer as the
  # v0.5.1-byte-identity test.
  _norm() {
    perl -CSD -pe '
      s/\x1b\[[0-9;]*[A-Za-z]//g;
      s/^(?:\x{1FA94}|\x{1FA84}|\x{2728}|\x{1F4AB})(?:\s+cpu\s+\S+)?\s*\n//;
      s/^(?:\x{1FA94}|\x{1FA84}|\x{2728}|\x{1F4AB})\s*//;
    '
  }
  local _a _b
  _a=$(printf '%s' "$_stdout_no_pending" | _norm)
  _b=$(printf '%s' "$_stdout_with_pending" | _norm)
  if [ "$_a" != "$_b" ]; then
    printf 'no-pending: %s\nwith-pending: %s\n' "$_a" "$_b" >&2
    diff <(printf '%s\n' "$_a") <(printf '%s\n' "$_b") >&2 || true
    false
  fi
}

@test "T11 wiring: 15s watchdog ceiling — labeler is killed if it runs too long" {
  # Hard ceiling test: synthesize a labeler that sleeps 60s, confirm the
  # cycle's watchdog kills it within ~16s (15s + 1s slack).
  #
  # Skip when the shell doesn't expose monotonic seconds — bats clock skew
  # would make this flaky.
  command -v date >/dev/null 2>&1 || skip "no date"
  # Shadow pp_oar_label_pending at the function level by sourcing a stub
  # AFTER lib/oar.sh. Define it as a function on PATH via fakebin won't
  # help (statusline calls it via `command -v` then function-name) — we
  # have to inject a fake lib. The cleanest path: write a shim oar.sh
  # under a temp PP_ROOT-substitute and run statusline.sh with that.
  #
  # Simpler: this is a known-hard-to-test invariant. Skip-by-default per
  # plan ("can be skip-by-default"). The pattern is exercised in the
  # bash review of the source code itself.
  skip "watchdog timing is hard to test reliably; see statusline.sh:1422 for the kill-after-15s pattern"
}

# ========================================================
# T11 source-order regression guard
# ========================================================

@test "T11 source-order: bin/statusline.sh sources lib/oar.sh" {
  # Defends against accidentally removing the source line. shellcheck
  # disable comment lives on the line above the actual `.` directive.
  grep -q '\. "\$_pp_bin_dir/\.\./lib/oar\.sh"' "$PP_ROOT/bin/statusline.sh"
}

@test "T11 source-order: bin/statusline.sh sources lib/hallucination.sh (Task 12 precondition)" {
  grep -q '\. "\$_pp_bin_dir/\.\./lib/hallucination\.sh"' "$PP_ROOT/bin/statusline.sh"
}

@test "T11 wiring: statusline.sh contains the PP_OAR_ENABLE gate + watchdog scaffolding" {
  # Code-shape assertion — guards against the integration block being
  # accidentally deleted by a future refactor.
  grep -q 'PP_OAR_ENABLE:-0' "$PP_ROOT/bin/statusline.sh"
  grep -q 'pp_oar_label_pending' "$PP_ROOT/bin/statusline.sh"
  # Watchdog pattern: kill -0 polling loop + kill -9 escalation.
  grep -q 'kill -0 "\$_pp_oar_pid"' "$PP_ROOT/bin/statusline.sh"
  grep -q 'kill -9 "\$_pp_oar_pid"' "$PP_ROOT/bin/statusline.sh"
}
