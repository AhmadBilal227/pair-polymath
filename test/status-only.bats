#!/usr/bin/env bats
# Status-only mode contract (config/default.env): PP_EXTERNAL_LLM=0 means
# "disable all LLM calls". That must cover the teacher tip digest too —
# both the background refresh (curl HN/arXiv + gpt-5-mini) and the line-2
# display of cached tips. Regression guard for the gap where only the
# advisor cycle checked the flag and the teacher kept running while paused.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/pair-polymath/config" "$HOME/.claude/cache"
  echo 'PP_EXTERNAL_LLM=0' > "$HOME/.claude/pair-polymath/config/user.env"

  # curl/llm shims that record any invocation as a marker file
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ntouch "%s/curl-called"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/curl"
  printf '#!/bin/sh\ntouch "%s/llm-called"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/llm"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl" "$BATS_TEST_TMPDIR/bin/llm"
}

run_statusline() {
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c \
    "cat '${BATS_TEST_DIRNAME}/fixtures/stdin-sample.json' | bash '${BATS_TEST_DIRNAME}/../bin/statusline.sh'"
}

@test "status-only: paused mode spawns no tip fetch (no curl, no llm)" {
  # No tip cache in the shimmed HOME → refresh would be due if ungated.
  # Clear the global fetch lock so a fresh real-machine lock can't mask the bug.
  rmdir /tmp/cc-tips-fetch.lock.d 2>/dev/null || true
  run_statusline
  [ "$status" -eq 0 ]
  sleep 2  # background fetcher (if wrongly spawned) runs detached
  [ ! -f "$BATS_TEST_TMPDIR/curl-called" ]
  [ ! -f "$BATS_TEST_TMPDIR/llm-called" ]
}

@test "status-only: paused mode does not display cached teacher tips" {
  # Fresh cache (age < 1800s) so the refresh path is idle either way;
  # only the display gate is under test.
  printf 'PAUSED MODE DISPLAY CANARY TOPIC|||body text\n' > "$HOME/.claude/cache/cc-tips.txt"
  run_statusline
  [ "$status" -eq 0 ]
  [[ "$output" != *"PAUSED MODE DISPLAY CANARY"* ]]
}

@test "status-only: enabled mode still displays cached tips (control)" {
  echo 'PP_EXTERNAL_LLM=1' > "$HOME/.claude/pair-polymath/config/user.env"
  printf 'ENABLED MODE DISPLAY CANARY TOPIC|||body text\n' > "$HOME/.claude/cache/cc-tips.txt"
  run_statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENABLED MODE DISPLAY CANARY"* ]]
}
