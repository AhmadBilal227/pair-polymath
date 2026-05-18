#!/usr/bin/env bats
# Advisory usefulness/noise scoring.

setup() {
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR/oar"
  PROJECT="$HOME/project"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init >/dev/null 2>&1
  export CLAUDE_PROJECT_DIR="$PROJECT"
  # shellcheck source=../lib/project-identity.sh
  . "$PP_ROOT/lib/project-identity.sh"
  PID_CURRENT=$(pp_project_id "$PROJECT")
}

teardown() {
  rm -rf "$HOME"
}

@test "insights score: scores useful, noisy, repeated, and follow-through signals" {
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --arg ts "$now_iso" --arg pid "$PID_CURRENT" '
    {schema_version:2,lens:"ENGINEERING",labeled_at:$ts,outcome:"acted",
     evidence:"Run bats test/oar-labeler.bats after fixing pp_oar_label_pending in lib/oar.sh.",
     cited_paths:["lib/oar.sh"], cited_symbols:["pp_oar_label_pending"],
     confidence:"exact",identity:"live-1",project_id:$pid}' \
    > "$PP_CACHE_DIR/oar-labeled.jsonl"
  secret="sk-abcdefghijklmnopqrstuvwxyz123456"
  jq -nc --arg ts "$now_iso" --arg pid "$PID_CURRENT" --arg secret "$secret" '
    {source:"session_log_bootstrap",confidence:"legacy_inferred",ts:$ts,session_id:"b1",
     lens:"SECURITY",topic:"maybe risky token handling",body:("Maybe this could be unverified and noisy " + $secret),
     topic_hash:"repeat-topic",body_hash:"body-a",identity:"boot-1",project_id:$pid,
     cited_paths:[],cited_symbols:[]}' \
    > "$PP_STATE_DIR/oar/bootstrap-labeled.jsonl"
  jq -nc --arg ts "$now_iso" --arg pid "$PID_CURRENT" '
    {source:"session_log_bootstrap",confidence:"legacy_inferred",ts:$ts,session_id:"b2",
     lens:"SECURITY",topic:"maybe risky token handling",body:"Maybe this could repeat without grounding.",
     topic_hash:"repeat-topic",body_hash:"body-b",identity:"boot-2",project_id:$pid,
     cited_paths:[],cited_symbols:[]}' \
    >> "$PP_STATE_DIR/oar/bootstrap-labeled.jsonl"

  run bash "$PP_ROOT/bin/polymath" insights score --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .total == 3
    and (.by_lens[] | select(.lens == "ENGINEERING") | .useful_looking == 1 and .acted_referenced == 1)
    and (.by_lens[] | select(.lens == "SECURITY") | .noisy_looking == 2 and .repeated == 2)
  ' >/dev/null
  [ -s "$PP_STATE_DIR/insights/score.jsonl" ]
  ! grep -q "$secret" "$PP_STATE_DIR/insights/score.jsonl"
  grep -q '\[REDACTED-OPENAI\]' "$PP_STATE_DIR/insights/score.jsonl"
  jq -s -e 'all(.[]; (has("body") | not) and (has("cited_paths") | not) and (has("cited_symbols") | not))' \
    "$PP_STATE_DIR/insights/score.jsonl" >/dev/null
}

@test "insights score: current project is default and --all-projects is explicit" {
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --arg ts "$now_iso" --arg pid "$PID_CURRENT" '
    {schema_version:2,lens:"ENGINEERING",labeled_at:$ts,outcome:"referenced",
     evidence:"Verify lib/router.sh before changing routing.",cited_paths:["lib/router.sh"],
     cited_symbols:[],confidence:"exact",identity:"current",project_id:$pid}' \
    > "$PP_CACHE_DIR/oar-labeled.jsonl"
  jq -nc --arg ts "$now_iso" '
    {schema_version:2,lens:"PRODUCT_BIZ",labeled_at:$ts,outcome:"ignored",
     evidence:"Verify another project launch checklist.",cited_paths:["README.md"],
     cited_symbols:[],confidence:"exact",identity:"other",project_id:"ffffffffffffffff"}' \
    >> "$PP_CACHE_DIR/oar-labeled.jsonl"

  run bash "$PP_ROOT/bin/polymath" insights score --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.total == 1 and .by_lens[0].lens == "ENGINEERING"' >/dev/null

  run bash "$PP_ROOT/bin/polymath" insights score --all-projects --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.total == 2 and (.by_lens | length) == 2' >/dev/null
  jq -e 'select(.project_id == "ffffffffffffffff") | .scores.noise_risk >= 2' \
    "$PP_STATE_DIR/insights/score.jsonl" >/dev/null
}

@test "insights score: rejects invalid window" {
  run bash "$PP_ROOT/bin/polymath" insights score --window nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"positive integer"* ]]
}
