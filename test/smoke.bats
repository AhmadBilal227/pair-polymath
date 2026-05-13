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
  echo "$out" | grep -qE 'idle —|✨|⚠|▸'
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
