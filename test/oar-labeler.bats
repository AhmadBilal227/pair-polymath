#!/usr/bin/env bats
# v0.5.2 — OAR labeler. Spec: docs/v0.5.2-oar-hallucination-spec.md

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}

# GPT review #6: skip identity tests when no hash tool is available
# anywhere on PATH. The fallback chain ends in a PP_OAR_NO_HASH_TOOL_*
# sentinel which is 64 chars but is NOT a sha256 — tests asserting
# determinism still pass on the sentinel, but the spec's "sha256" claim
# isn't being exercised. Surface this as a skip so CI doesn't lie.
_pp_have_hash_tool() {
  command -v shasum >/dev/null 2>&1 \
    || command -v sha256sum >/dev/null 2>&1 \
    || command -v sha256 >/dev/null 2>&1 \
    || command -v openssl >/dev/null 2>&1 \
    || command -v md5sum >/dev/null 2>&1 \
    || command -v md5 >/dev/null 2>&1
}
teardown() { rm -rf "$HOME"; }

@test "row_identity: sha256 of sid|lens|hash|inject_ts is deterministic" {
  _pp_have_hash_tool || skip "no sha256/openssl/md5 on PATH"
  . "$PP_ROOT/lib/oar.sh"
  local id1 id2
  id1=$(pp_oar_row_identity "sess-A" "ENGINEERING" "h1" "2026-05-15T00:00:00Z")
  id2=$(pp_oar_row_identity "sess-A" "ENGINEERING" "h1" "2026-05-15T00:00:00Z")
  [ "$id1" = "$id2" ]
  # 64 hex chars (sha256)
  [ "${#id1}" -eq 64 ]
}

@test "row_identity: inject_ts is part of the key (replay-at-different-time differs)" {
  _pp_have_hash_tool || skip "no sha256/openssl/md5 on PATH"
  . "$PP_ROOT/lib/oar.sh"
  local id1 id2
  id1=$(pp_oar_row_identity "sess-A" "ENGINEERING" "h1" "2026-05-15T00:00:00Z")
  id2=$(pp_oar_row_identity "sess-A" "ENGINEERING" "h1" "2026-05-15T00:00:01Z")
  [ "$id1" != "$id2" ]
}

@test "row_identity: differs when any of the 4 fields changes" {
  _pp_have_hash_tool || skip "no sha256/openssl/md5 on PATH"
  . "$PP_ROOT/lib/oar.sh"
  local base id_lens id_hash id_sid
  base=$(pp_oar_row_identity   "S" "L" "H" "T")
  id_sid=$(pp_oar_row_identity "X" "L" "H" "T")
  id_lens=$(pp_oar_row_identity "S" "X" "H" "T")
  id_hash=$(pp_oar_row_identity "S" "L" "X" "T")
  [ "$base" != "$id_sid" ]
  [ "$base" != "$id_lens" ]
  [ "$base" != "$id_hash" ]
}

@test "with_row_timeout: returns command exit code when under cap" {
  . "$PP_ROOT/lib/oar.sh"
  run pp_oar_with_row_timeout 2 true
  [ "$status" -eq 0 ]
}

@test "with_row_timeout: returns non-zero when command exceeds cap" {
  . "$PP_ROOT/lib/oar.sh"
  # Skip if neither timeout nor gtimeout is available (BusyBox/Alpine
  # without coreutils): the function passes through, so the test is moot.
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    skip "no timeout binary on PATH"
  fi
  run pp_oar_with_row_timeout 1 sleep 3
  [ "$status" -ne 0 ]
}

@test "with_row_timeout: passes through when no timeout binary available" {
  . "$PP_ROOT/lib/oar.sh"
  # Task-4 review finding: the probe-once cache persists across tests in
  # the same bats process (the source guard prevents re-init). On a host
  # WITH `timeout` installed, prior tests cache _PP_OAR_TIMEOUT_CMD="timeout"
  # and this test then runs `timeout 1 true` rather than exercising the
  # pass-through branch. Clear the cache explicitly so the stubbed PATH
  # below actually triggers a re-probe → "checked, none found" → fall-through.
  unset _PP_OAR_TIMEOUT_CMD
  # GPT-review #8: also unalias / unset any function shadow of `timeout`
  # so the test's PATH scrub really blocks the lookup. `type -P` (used by
  # the implementation) ignores aliases + functions, so this is defensive
  # against operator shells that wrap timeout for their convenience.
  unalias timeout 2>/dev/null || true
  unset -f timeout 2>/dev/null || true
  unalias gtimeout 2>/dev/null || true
  unset -f gtimeout 2>/dev/null || true
  # Force pass-through via PATH manipulation. Function's first-call probe
  # caches the lookup result; since PATH is scrubbed on THIS invocation,
  # neither `timeout` nor `gtimeout` will be findable, and the function
  # falls through to direct exec of the command. We use the bash builtin
  # `true` (not /bin/true — macOS keeps it at /usr/bin/true, so the bare
  # absolute path is non-portable). Builtins resolve before PATH lookup,
  # so this exercises the pass-through branch without depending on any
  # external binary location.
  PATH="$(pwd)" run pp_oar_with_row_timeout 1 true
  [ "$status" -eq 0 ]
}

@test "with_row_timeout: no-command invocation returns 2 (caller bug)" {
  # GPT review #9 + #5: without the explicit "command required" guard,
  # zero-arg invocation would fall through to `timeout 3` (usage error)
  # or empty $@ pass-through ("command not found" from shell). Now
  # returns 2 with a clear stderr message — a caller bug, not a flake.
  . "$PP_ROOT/lib/oar.sh"
  run pp_oar_with_row_timeout 5
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'no command given'
}

@test "with_row_timeout: zero-arg invocation also returns 2 (uses default secs)" {
  # GPT review #9: with PP_OAR_ROW_TIMEOUT_S defaulted, calling with
  # zero positional args MUST NOT trigger "shift count out of range"
  # under set -e. The shift is now guarded; we get the "no command
  # given" error path instead. This test would have caught GPT #1.
  . "$PP_ROOT/lib/oar.sh"
  run pp_oar_with_row_timeout
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'no command given'
}

@test "with_row_timeout: SECS=0 clamps to default (no zero-flake)" {
  # GPT review #7: coreutils `timeout 0 cmd` fires instantly. Caller
  # passing 0 (or unset env) should NOT collapse the cap to zero —
  # validation clamps to 3.
  . "$PP_ROOT/lib/oar.sh"
  run pp_oar_with_row_timeout 0 true
  [ "$status" -eq 0 ]   # `true` completes well within the clamped 3s
}
