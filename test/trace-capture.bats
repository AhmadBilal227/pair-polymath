#!/usr/bin/env bats
# v0.5.4 trace capture: bounded JSONL emitter + statusline wiring.

setup() {
  HOME="$(mktemp -d)"; export HOME
  CLAUDE_DIR="$HOME/.claude"; export CLAUDE_DIR
  PP_CACHE_DIR="$CLAUDE_DIR/cache"; mkdir -p "$PP_CACHE_DIR"; export PP_CACHE_DIR
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"; mkdir -p "$PP_STATE_DIR/config"; export PP_STATE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; export PP_ROOT
}

teardown() {
  rm -rf "$HOME"
}

_mode() {
  # GNU-first probe (matches lib/oar.sh:637 canonical pattern). `stat -f`
  # on GNU coreutils means "filesystem format" — prints fs metadata, doesn't
  # fail — so BSD-first probe on Ubuntu CI yields non-numeric output and the
  # `[…] = "600"` comparison always fails. Same bug class as the v0.5.2.1
  # doctor #22 fix.
  if stat -c %a /dev/null >/dev/null 2>&1; then
    stat -c %a "$1" 2>/dev/null
  else
    stat -f %Lp "$1" 2>/dev/null
  fi
}

@test "trace emitter: disabled by default" {
  . "$PP_ROOT/lib/metrics.sh"
  unset PP_TRACE_ENABLE
  pp_trace_emit_cycle '{"schema_version":1}'
  [ ! -f "$PP_CACHE_DIR/trace-cycle.jsonl" ]
}

@test "trace emitter: enabled writes one owner-only JSONL row" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_TRACE_ENABLE=1
  pp_trace_emit_cycle '{"schema_version":1,"session_sha8":"abc12345"}'
  [ -f "$PP_CACHE_DIR/trace-cycle.jsonl" ]
  [ "$(wc -l < "$PP_CACHE_DIR/trace-cycle.jsonl" | tr -d ' ')" = "1" ]
  jq -e '.schema_version == 1 and .session_sha8 == "abc12345"' "$PP_CACHE_DIR/trace-cycle.jsonl" >/dev/null
  [ "$(_mode "$PP_CACHE_DIR/trace-cycle.jsonl")" = "600" ]
}

@test "trace emitter: force-disable wins over enable" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_TRACE_ENABLE=1 PP_TRACE_FORCE_DISABLE=1
  pp_trace_emit_cycle '{"schema_version":1}'
  [ ! -f "$PP_CACHE_DIR/trace-cycle.jsonl" ]
}

@test "trace emitter: malformed, empty, and non-object payloads fail open" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_TRACE_ENABLE=1
  pp_trace_emit_cycle ''
  pp_trace_emit_cycle 'not-json'
  pp_trace_emit_cycle '["array-not-object"]'
  [ ! -f "$PP_CACHE_DIR/trace-cycle.jsonl" ]
}

@test "trace emitter: rotates with shared JSONL rotation helper" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_TRACE_ENABLE=1 PP_TRACE_MAX_BYTES=10
  printf '01234567890123456789\n' > "$PP_CACHE_DIR/trace-cycle.jsonl"
  pp_trace_emit_cycle '{"schema_version":1,"new":true}'
  [ -f "$PP_CACHE_DIR/trace-cycle.jsonl.1" ]
  jq -e '.new == true' "$PP_CACHE_DIR/trace-cycle.jsonl" >/dev/null
}

@test "trace emitter: drops rows over row max instead of archiving huge payloads" {
  . "$PP_ROOT/lib/metrics.sh"
  export PP_TRACE_ENABLE=1 PP_TRACE_ROW_MAX_CHARS=24
  pp_trace_emit_cycle '{"schema_version":1,"large":"xxxxxxxxxxxxxxxxxxxxxxxx"}'
  [ ! -f "$PP_CACHE_DIR/trace-cycle.jsonl" ]
}

@test "statusline trace: emits bounded metadata without raw prompt payload text" {
  PP_TX="$HOME/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"RAW_USER_TEXT sk-secret-1234567890"}}' > "$PP_TX"
  PP_STDIN="$HOME/stdin.json"
  printf '{"session_id":"trace-test-session","workspace":{"current_dir":"%s"},"model":{"display_name":"Sonnet 4.6"},"transcript_path":"%s","cost":{"total_cost_usd":0.0},"exceeds_200k_tokens":false}\n' \
    "$HOME" "$PP_TX" > "$PP_STDIN"

  PP_FAKEBIN="$HOME/fakebin"; mkdir -p "$PP_FAKEBIN"
  printf '#!/bin/sh\nprintf "SILENT\\n"\n' > "$PP_FAKEBIN/llm"
  chmod +x "$PP_FAKEBIN/llm"
  PATH="$PP_FAKEBIN:$PATH"; export PATH

  cat > "$PP_STATE_DIR/config/user.env" <<'EOF'
PP_TRACE_ENABLE=1
PP_EXTERNAL_LLM=1
EOF
  export PP_EVAL_MODE=1
  bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" >/dev/null 2>&1 || true

  [ -f "$PP_CACHE_DIR/trace-cycle.jsonl" ]
  [ "$(wc -c < "$PP_CACHE_DIR/trace-cycle.jsonl" | tr -d ' ')" -lt 8192 ]
  jq -e '
    .schema_version == 1
    and (.session_sha8 | test("^[0-9a-f]{8}$"))
    and (.cwd_sha8 | test("^[0-9a-f]{8}$"))
    and .mode.eval_mode == true
    and .prompt_versions["analyst-primary"] == "0.5.4.0"
    and .router.decision_source == "eval_bypass"
    and (.router.signals | type == "object")
    and (.router.picked_lenses | type == "array")
    and (.cycle.lens_count >= 1)
    and .privacy.raw_transcript_archived == false
    and .privacy.grounded_facts_archived == false
    and .privacy.observation_bodies_archived == false
    and .privacy.payload_previews_archived == false
  ' "$PP_CACHE_DIR/trace-cycle.jsonl" >/dev/null
  ! grep -q 'RAW_USER_TEXT' "$PP_CACHE_DIR/trace-cycle.jsonl"
  ! grep -q 'sk-secret-1234567890' "$PP_CACHE_DIR/trace-cycle.jsonl"
  ! grep -q 'trace-test-session' "$PP_CACHE_DIR/trace-cycle.jsonl"
  ! grep -q "$HOME" "$PP_CACHE_DIR/trace-cycle.jsonl"
}
