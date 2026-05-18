#!/usr/bin/env bats
# End-to-end smoke: bin/statusline.sh must exit 0 on a variety of stdin shapes.

@test "statusline.sh: exits 0 with sample stdin" {
  run bash -c "cat '${BATS_TEST_DIRNAME}/fixtures/stdin-sample.json' | bash '${BATS_TEST_DIRNAME}/../bin/statusline.sh'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "statusline.sh: freshness — stale lens caches (>10min) are skipped (v0.4 UX)" {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/cache"
  export CLAUDE_DIR
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  export PP_CACHE_DIR
  STALE="$PP_CACHE_DIR/cc-monitor-bats-stale-ENGINEERING.txt"
  printf 'ENG: stale observation that is long enough to pass twenty char gate|||body\n' > "$STALE"
  touch -d "15 minutes ago" "$STALE" 2>/dev/null \
    || touch -A -001500 "$STALE" 2>/dev/null \
    || skip "no portable mtime backdate"
  out=$(printf '{"session_id":"bats-stale","model":{"display_name":"S"},"workspace":{"current_dir":"%s"},"transcript_path":"/tmp/none","cost":{"total_cost_usd":0.0}}' "$(pwd)" \
    | bash "${BATS_TEST_DIRNAME}/../bin/statusline.sh" 2>&1)
  # The stale observation must NOT appear in the rendered output.
  ! echo "$out" | grep -qF 'stale observation that is long enough'
  # The idle fallback OR another fresh observation should appear instead.
  # v0.5.5 brand: ⚛ now leads advisor lines (replaces ⚠ on mon_valid branch);
  # constellation braille frames ⠁⠂⠄⡀ lead cycle-in-flight lines.
  echo "$out" | grep -qE 'idle —|✨|⚠|▸|⚛|⠁|⠂|⠄|⡀'
}

@test "statusline.sh: freshness — idle fallback when nothing fresh (v0.4 UX)" {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/cache"
  export CLAUDE_DIR
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  export PP_CACHE_DIR
  # No lens caches at all → all probe iterations should miss → idle fallback.
  out=$(printf '{"session_id":"bats-idle","model":{"display_name":"S"},"workspace":{"current_dir":"%s"},"transcript_path":"/tmp/none","cost":{"total_cost_usd":0.0}}' "$(pwd)" \
    | bash "${BATS_TEST_DIRNAME}/../bin/statusline.sh" 2>&1)
  # If no tip OR mon cache exists, idle fallback fires.
  # We can't guarantee no tip cache (TIP_CACHE may exist from prior runs)
  # — so assert either idle fallback OR a tip line.
  echo "$out" | grep -qE 'idle —|▸'
}

@test "statusline.sh: handles missing session_id" {
  run bash -c "echo '{}' | bash '${BATS_TEST_DIRNAME}/../bin/statusline.sh'"
  [ "$status" -eq 0 ]
}

@test "statusline.sh: handles malformed JSON gracefully" {
  run bash -c "echo 'not-json' | bash '${BATS_TEST_DIRNAME}/../bin/statusline.sh'"
  [ "$status" -eq 0 ]
}

@test "statusline.sh: cycle lock is not reclaimed before derived workload TTL" {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT

  fakebin="$HOME/fakebin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nprintf "SILENT\\n"\n' > "$fakebin/llm"
  chmod +x "$fakebin/llm"

  tx="$HOME/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' > "$tx"
  sid="bats-lock-ttl-$$"
  lock="/tmp/pp-fetch-${sid}.lock"
  rm -rf "$lock"
  mkdir "$lock"
  touch -d "10 minutes ago" "$lock" 2>/dev/null \
    || touch -A -001000 "$lock" 2>/dev/null \
    || skip "no portable mtime backdate"

  run env PATH="$fakebin:$PATH" PP_EVAL_MODE=1 bash -c \
    'printf "{\"session_id\":\"%s\",\"workspace\":{\"current_dir\":\"%s\"},\"model\":{\"display_name\":\"S\"},\"transcript_path\":\"%s\",\"cost\":{\"total_cost_usd\":0.0}}\n" "$0" "$1" "$2" | bash "$PP_ROOT/bin/statusline.sh" >/dev/null 2>&1' \
    "$sid" "$HOME" "$tx"
  [ "$status" -eq 0 ]
  [ -d "$lock" ]
  rm -rf "$lock" "$HOME"
}

@test "statusline.sh: PP_CYCLE_LOCK_STALE_S override can reclaim stale cycle lock" {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT

  fakebin="$HOME/fakebin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nprintf "SILENT\\n"\n' > "$fakebin/llm"
  chmod +x "$fakebin/llm"

  tx="$HOME/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' > "$tx"
  sid="bats-lock-override-$$"
  lock="/tmp/pp-fetch-${sid}.lock"
  rm -rf "$lock"
  mkdir "$lock"
  touch -d "10 seconds ago" "$lock" 2>/dev/null \
    || touch -A -000010 "$lock" 2>/dev/null \
    || skip "no portable mtime backdate"

  run env PATH="$fakebin:$PATH" PP_EVAL_MODE=1 PP_CYCLE_LOCK_STALE_S=1 bash -c \
    'printf "{\"session_id\":\"%s\",\"workspace\":{\"current_dir\":\"%s\"},\"model\":{\"display_name\":\"S\"},\"transcript_path\":\"%s\",\"cost\":{\"total_cost_usd\":0.0}}\n" "$0" "$1" "$2" | bash "$PP_ROOT/bin/statusline.sh" >/dev/null 2>&1' \
    "$sid" "$HOME" "$tx"
  [ "$status" -eq 0 ]
  [ ! -d "$lock" ]
  rm -rf "$lock" "$HOME"
}
