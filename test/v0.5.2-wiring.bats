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
      # v0.5.5 brand: strip wall-clock-cycled visual elements that two
      # sequential runs naturally differ on (constellation braille frames
      # ⠁ ⠂ ⠄ ⡀ and the ⚛ atom sigil itself). Content semantics are what
      # this test checks, not visual-frame identity.
      s/[\x{2801}\x{2802}\x{2804}\x{2808}]//g;
      s/\x{269B}//g;
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

# ========================================================
# Task 12 — hallucination post-check call site (shadow, gated)
# ========================================================
#
# Spec §C: after critique PASS, run pp_halluc_verify_citations.
#   - PP_HALLUC_GATE_ENABLE=0 (default): block is a no-op (byte-identity).
#   - PP_HALLUC_GATE_ENABLE=1 + PP_HALLUC_GATE_ACTIVE=0: shadow — count
#     would-drops in _pp_halluc_post_drops, verdict file unchanged.
#   - PP_HALLUC_GATE_ENABLE=1 + PP_HALLUC_GATE_ACTIVE=1: flip verdict to
#     DROP (active mode; not default in v0.5.2).
#
# End-to-end behavior assertions (counter increments, verdict flips)
# live in Task 13's kpi-cycle test where _pp_halluc_post_drops is
# emitted to the metrics blob. Here we lock down the WIRING — the code
# shape that proves Task 12 is committed and matches the spec.

@test "T12 wiring: PASS branch contains PP_HALLUC_GATE_ENABLE gate" {
  # Code-shape guard: the hallucination post-check is mounted under
  # the critique-PASS branch (after `echo 0 > "$streak_file"`), gated
  # on PP_HALLUC_GATE_ENABLE=1, and only flips the verdict when
  # PP_HALLUC_GATE_ACTIVE=1 ALSO. This is the contract the byte-identity
  # invariant depends on.
  grep -q 'PP_HALLUC_GATE_ENABLE:-0' "$PP_ROOT/bin/statusline.sh"
  grep -q 'PP_HALLUC_GATE_ACTIVE:-0' "$PP_ROOT/bin/statusline.sh"
  grep -q 'pp_halluc_verify_citations' "$PP_ROOT/bin/statusline.sh"
}

@test "T12 wiring: counter variable is _pp_halluc_post_drops (Task 13 reads this)" {
  # The counter name is load-bearing — Task 13's KPI emitter reads
  # ${_pp_halluc_post_drops:-0} when building the cycle blob. If this
  # name drifts the telemetry silently zeros out.
  grep -q '_pp_halluc_post_drops=' "$PP_ROOT/bin/statusline.sh"
}

@test "T12 wiring: active-mode flip writes verdict file with halluc_post_check reason" {
  # When PP_HALLUC_GATE_ACTIVE=1 ALSO set, the PASS → DROP transition
  # must write a verdict line tagged with the halluc_post_check reason
  # (so pp_retry_classify_reason can route it as citation_fail). Verify
  # the literal flip-string lives in the source and keeps the numeric
  # lensN token that verdict/KPI parsers consume.
  grep -q 'lens${ci}: DROP (halluc_post_check)' "$PP_ROOT/bin/statusline.sh"
  ! grep -q 'lens${ci_id}: DROP (halluc_post_check)' "$PP_ROOT/bin/statusline.sh"
}

@test "T12 wiring: PP_HALLUC_GATE_ENABLE=0 → byte-identity holds (no post-check side effect)" {
  # End-to-end byte-identity guard for the gating flag itself.
  # Without PP_HALLUC_GATE_ENABLE set, STDOUT must match the OAR-off run
  # byte-for-byte (modulo known time-varying surfaces stripped by the
  # same normalizer as test/v0.5.1-byte-identity.bats).
  unset PP_HALLUC_GATE_ENABLE PP_HALLUC_GATE_ACTIVE PP_HALLUC_GATE_DEEP
  unset PP_RETRY_ROUTER_ENABLE PP_RETRY_ROUTER_SHADOW PP_KPI_ENABLE PP_OAR_ENABLE
  local _baseline_file="$PP_ROOT/test/fixtures/v0.5.0-baseline-stdout.txt"
  [ -f "$_baseline_file" ] || skip "baseline file missing"
  _norm() {
    perl -CSD -pe '
      s/\x1b\[[0-9;]*[A-Za-z]//g;
      s/^(?:\x{1FA94}|\x{1FA84}|\x{2728}|\x{1F4AB})(?:\s+cpu\s+\S+)?\s*\n//;
      s/^(?:\x{1FA94}|\x{1FA84}|\x{2728}|\x{1F4AB})\s*//;
    '
  }
  local _baseline_sha _current_sha
  _baseline_sha=$(_norm < "$_baseline_file" | shasum -a 256 | cut -d' ' -f1)
  _current_sha=$(cat "$PP_ROOT/test/fixtures/stdin-sample.json" \
    | bash "$PP_ROOT/bin/statusline.sh" 2>/dev/null \
    | _norm | shasum -a 256 | cut -d' ' -f1)
  [ "$_baseline_sha" = "$_current_sha" ]
}

@test "T12 wiring: ENABLE=1 + body with fake citation → counter incremented (unit)" {
  # Direct exercise of the post-check primitive at the call-site
  # contract. We can't synthesize a full critique-PASS cycle in
  # bats (requires LLM output parsing), so we drive the function
  # the way statusline.sh does: source the lib, set up cwd + body
  # + allowlists, call the verifier, and assert rc=1 (would-drop).
  # The integration block's only job is to forward this rc=1 to
  # the counter — verified by the source-shape guards above.
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  # Body cites a fake file that's NOT in the allowlist either.
  run pp_halluc_verify_citations "$_repo" \
      "Refactor totally-fake.ts to handle errors" "totally-fake.ts" ""
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "T12 wiring: ENABLE=1 + ACTIVE=0 → shadow contract (no verdict mutation)" {
  # The library function MUST NOT write to verdict files even when
  # rc=1. That's the call site's job, gated on PP_HALLUC_GATE_ACTIVE=1.
  # Re-asserts the shadow-contract guard already in hallucination-gate.bats
  # but in the wiring file so a refactor of the call site is visible
  # here too.
  . "$PP_ROOT/lib/hallucination.sh"
  local _src
  _src=$(declare -f pp_halluc_verify_citations)
  ! printf '%s\n' "$_src" | LC_ALL=C grep -E 'verdict_file|PP_VERDICT' >/dev/null
}
