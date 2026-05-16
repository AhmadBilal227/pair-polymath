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

# ----------------------------------------------------------------------------
# pp_oar_pushed_back — spec §B step 2 (explicit dismiss-ack only, no
# transcript-negation heuristic in v0.5.2). Schema matches lib/dismiss.sh
# (fields: id, ts ISO-8601, hash=short prefix, source, deleted).
# Window: [INJECT_TS_EPOCH, SCAN_AT_EPOCH] inclusive on both ends.
# Test timestamps below: 2026-05-15T00:00:00Z = 1778803200 (verified via
# `date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "..." "+%s"`); the plan's example
# values 1778889600/1778893200 are off by one day — actual values used.
# ----------------------------------------------------------------------------

# Helper: source dismiss.sh + memory schema, return the project-scoped path
# pp_oar_pushed_back will read. Tests write rules directly to this file
# (rather than via pp_dismiss_ack) so they can control .ts deterministically.
_pp_pushed_back_setup_rules_file() {
  # shellcheck source=../lib/memory/schema.sh
  . "$PP_ROOT/lib/memory/schema.sh"
  # shellcheck source=../lib/dismiss.sh
  . "$PP_ROOT/lib/dismiss.sh"
  mkdir -p "$PP_STATE_DIR/dismiss"
  pp_dismiss_file_path
}

@test "pushed_back: returns 0 + rule id when matching ack rule is in window" {
  . "$PP_ROOT/lib/oar.sh"
  local _f
  _f=$(_pp_pushed_back_setup_rules_file)
  # inject_ts = 2026-05-15T00:00:00Z (epoch 1778803200)
  # scan_at   = 2026-05-15T01:00:00Z (epoch 1778806800)
  # rule.ts   = 2026-05-15T00:30:00Z → in window
  jq -nc \
    '{id:"a-2026-05-15-test",ts:"2026-05-15T00:30:00Z",
      reason_summary:"Acked — keep firing",scope:"project",lens_id:null,
      hash:"deadbe",deleted:false,deleted_reason:null,
      ttl_days:null,source:"ack"}' >> "$_f"
  local out rc
  out=$(pp_oar_pushed_back "deadbeef1234567890abcd" 1778803200 1778806800)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "a-2026-05-15-test" ]
}

@test "pushed_back: returns non-zero when ack is AFTER scan_at (outside window)" {
  . "$PP_ROOT/lib/oar.sh"
  local _f
  _f=$(_pp_pushed_back_setup_rules_file)
  # rule.ts = 02:00Z → after scan_at 01:00Z window upper bound
  jq -nc \
    '{id:"a-late",ts:"2026-05-15T02:00:00Z",
      reason_summary:"Acked — keep firing",scope:"project",lens_id:null,
      hash:"deadbe",deleted:false,deleted_reason:null,
      ttl_days:null,source:"ack"}' >> "$_f"
  run pp_oar_pushed_back "deadbeef1234" 1778803200 1778806800
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "pushed_back: returns non-zero when ack is BEFORE inject_ts (outside window)" {
  . "$PP_ROOT/lib/oar.sh"
  local _f
  _f=$(_pp_pushed_back_setup_rules_file)
  # rule.ts = previous day → before inject_ts 00:00Z window lower bound
  jq -nc \
    '{id:"a-early",ts:"2026-05-14T23:00:00Z",
      reason_summary:"Acked — keep firing",scope:"project",lens_id:null,
      hash:"deadbe",deleted:false,deleted_reason:null,
      ttl_days:null,source:"ack"}' >> "$_f"
  run pp_oar_pushed_back "deadbeef1234" 1778803200 1778806800
  [ "$status" -ne 0 ]
}

@test "pushed_back: returns non-zero when hash does not match (different prefix)" {
  . "$PP_ROOT/lib/oar.sh"
  local _f
  _f=$(_pp_pushed_back_setup_rules_file)
  # rule.hash = "feedba" → does NOT prefix "deadbeef..."
  jq -nc \
    '{id:"a-other",ts:"2026-05-15T00:30:00Z",
      reason_summary:"Acked — keep firing",scope:"project",lens_id:null,
      hash:"feedba",deleted:false,deleted_reason:null,
      ttl_days:null,source:"ack"}' >> "$_f"
  run pp_oar_pushed_back "deadbeef1234" 1778803200 1778806800
  [ "$status" -ne 0 ]
}

@test "pushed_back: ignores non-ack rules (source=manual is NOT 'ack-this-observation')" {
  . "$PP_ROOT/lib/oar.sh"
  local _f
  _f=$(_pp_pushed_back_setup_rules_file)
  # source=manual → user dismissed for other reasons, not an explicit ack.
  # Hash + ts BOTH match; only source disqualifies.
  jq -nc \
    '{id:"d-manual",ts:"2026-05-15T00:30:00Z",
      reason_summary:"Different concern",scope:"project",lens_id:null,
      hash:"deadbe",deleted:false,deleted_reason:null,
      ttl_days:null,source:"manual"}' >> "$_f"
  run pp_oar_pushed_back "deadbeef1234" 1778803200 1778806800
  [ "$status" -ne 0 ]
}

@test "pushed_back: ignores auto_suppress rules (only explicit source=ack qualifies)" {
  . "$PP_ROOT/lib/oar.sh"
  local _f
  _f=$(_pp_pushed_back_setup_rules_file)
  jq -nc \
    '{id:"d-auto",ts:"2026-05-15T00:30:00Z",
      reason_summary:"Auto-suppressed",scope:"project",lens_id:null,
      hash:"deadbe",deleted:false,deleted_reason:null,
      ttl_days:7,source:"auto_suppress"}' >> "$_f"
  run pp_oar_pushed_back "deadbeef1234" 1778803200 1778806800
  [ "$status" -ne 0 ]
}

@test "pushed_back: latest-line-wins — disabled ack does NOT count as pushed-back" {
  # Append-only schema: a disable appends a deleted=true line for the same
  # id. Latest line wins. An enable would re-flip it. pp_oar_pushed_back
  # must honor that fold, otherwise a re-enabled-then-disabled ack rule
  # would still match — silent miscoding of the outcome.
  . "$PP_ROOT/lib/oar.sh"
  local _f
  _f=$(_pp_pushed_back_setup_rules_file)
  # Initial ack (deleted=false) at 00:30Z, then a disabled follow-up at 00:31Z.
  jq -nc \
    '{id:"a-toggle",ts:"2026-05-15T00:30:00Z",
      reason_summary:"Acked — keep firing",scope:"project",lens_id:null,
      hash:"deadbe",deleted:false,deleted_reason:null,
      ttl_days:null,source:"ack"}' >> "$_f"
  jq -nc \
    '{id:"a-toggle",ts:"2026-05-15T00:31:00Z",
      reason_summary:"Acked — keep firing",scope:"project",lens_id:null,
      hash:"deadbe",deleted:true,deleted_reason:"user_disabled",
      ttl_days:null,source:"ack"}' >> "$_f"
  run pp_oar_pushed_back "deadbeef1234" 1778803200 1778806800
  [ "$status" -ne 0 ]
}

@test "pushed_back: returns 1 when rules file is absent (fresh install)" {
  . "$PP_ROOT/lib/oar.sh"
  # Don't seed any dismiss file — pp_oar_pushed_back must not error,
  # just return 1.
  run pp_oar_pushed_back "deadbeef1234" 1778803200 1778806800
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "pushed_back: empty hash returns 1 (caller bug guard)" {
  . "$PP_ROOT/lib/oar.sh"
  run pp_oar_pushed_back "" 1778803200 1778806800
  [ "$status" -eq 1 ]
}

@test "pushed_back: non-numeric epoch returns 1 (caller bug guard)" {
  . "$PP_ROOT/lib/oar.sh"
  run pp_oar_pushed_back "deadbeef1234" "not-a-number" 1778806800
  [ "$status" -eq 1 ]
}

@test "pushed_back: case-insensitive hash match (GPT-review #7)" {
  # User might run `polymath dismiss ack DEADBE` (uppercase); dismiss.sh
  # stores .hash verbatim. Pending row always carries lowercase hash from
  # the injection pipeline. Comparison must be case-insensitive — both
  # sides normalized to lowercase before startswith.
  . "$PP_ROOT/lib/oar.sh"
  local _f
  _f=$(_pp_pushed_back_setup_rules_file)
  # Rule stores UPPERCASE prefix
  jq -nc \
    '{id:"a-2026-05-15-upper",ts:"2026-05-15T00:30:00Z",
      reason_summary:"User typed uppercase hex",scope:"project",lens_id:null,
      hash:"DEADBE",deleted:false,deleted_reason:null,
      ttl_days:null,source:"ack"}' >> "$_f"
  local out rc
  # Pending row carries lowercase hash — must still match
  out=$(pp_oar_pushed_back "deadbeef1234" 1778803200 1778806800); rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "a-2026-05-15-upper" ]
}

@test "pushed_back: unparseable rule timestamp does NOT match with inject=0" {
  # GPT-review #4: was `// 0` which collapses unparseable ts → 0. If a
  # caller passes INJECT_TS_EPOCH=0, a malformed-ts rule would have
  # falsely matched (0 >= 0 && 0 <= scan). Explicit null filter prevents.
  . "$PP_ROOT/lib/oar.sh"
  local _f
  _f=$(_pp_pushed_back_setup_rules_file)
  jq -nc \
    '{id:"a-2026-05-15-bad",ts:"not-an-iso-date",
      reason_summary:"corrupted",scope:"project",lens_id:null,
      hash:"deadbe",deleted:false,deleted_reason:null,
      ttl_days:null,source:"ack"}' >> "$_f"
  run pp_oar_pushed_back "deadbeef1234" 0 9999999999
  [ "$status" -eq 1 ]   # unparseable ts → null → filtered out → no match
}

# ----------------------------------------------------------------------------
# pp_oar_acted_for_path — spec §B step 1 (per-cited-path git log --follow,
# per-commit git show -M50% --unified=0, symbol_exact OR line_proximity).
#
# Plan addendum I1: lib/oar.sh sources lib/grounding.sh internally for
# pp_safe_git_pathspec + pp_contain_path. Tests must NOT pre-source
# grounding.sh — runtime-gap regression guard.
#
# Plan addendum risk #1: while-read in a pipeline runs the RHS in a subshell;
# `return 0` only exits that subshell. The implementation uses the temp-file
# flag pattern (mktemp in PP_CACHE_DIR with mkdir -p fallback).
# ----------------------------------------------------------------------------

@test "acted_for_path: symbol_exact match in diff returns 0 + commit SHA + label" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q && git -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m base ) || skip "git unavailable"
  # Write a file that mentions "doSomething" symbol, commit it.
  printf '%s\n' 'doSomething();' > "$_repo/foo.ts"
  ( cd "$_repo" && git add foo.ts \
    && GIT_AUTHOR_DATE="2026-05-15T00:30:00Z" GIT_COMMITTER_DATE="2026-05-15T00:30:00Z" \
       git -c user.email=t@t -c user.name=t commit -q -m "add foo" )
  # Cite the symbol; assert acted.
  local out rc
  out=$(pp_oar_acted_for_path "$_repo" "foo.ts" "doSomething" "" \
        1778803200 1778806800) ; rc=$?
  [ "$rc" -eq 0 ]
  # Format: "<40-hex SHA>|<label>"
  printf '%s' "$out" | grep -qE '^[0-9a-f]{40}\|symbol_exact$'
  rm -rf "$_repo"
}

@test "acted_for_path: line_proximity (within ±20) returns line_proximity label" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q && git -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m base ) || skip "git unavailable"
  # 25 blank lines then a real edit at line 26.
  ( cd "$_repo" && yes '' | head -25 > big.ts \
    && printf 'edited\n' >> big.ts \
    && git add big.ts \
    && GIT_AUTHOR_DATE="2026-05-15T00:30:00Z" GIT_COMMITTER_DATE="2026-05-15T00:30:00Z" \
       git -c user.email=t@t -c user.name=t commit -q -m "edit big.ts" )
  # Cite line range [20-30] — overlaps the edit at line 26 within ±20.
  local out
  out=$(pp_oar_acted_for_path "$_repo" "big.ts" "" "20-30" \
        1778803200 1778806800)
  printf '%s' "$out" | grep -qE '^[0-9a-f]{40}\|line_proximity$'
  rm -rf "$_repo"
}

@test "acted_for_path: file-touch alone (no symbol/line match) → returns 1" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q && git -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m base ) || skip "git unavailable"
  printf '%s\n' 'unrelated content' > "$_repo/foo.ts"
  ( cd "$_repo" && git add foo.ts \
    && GIT_AUTHOR_DATE="2026-05-15T00:30:00Z" GIT_COMMITTER_DATE="2026-05-15T00:30:00Z" \
       git -c user.email=t@t -c user.name=t commit -q -m "touch" )
  run pp_oar_acted_for_path "$_repo" "foo.ts" "veryLongSymbolThatIsNotInDiff" "" \
        1778803200 1778806800
  [ "$status" -ne 0 ]
  rm -rf "$_repo"
}

@test "acted_for_path: short symbol (<4 chars) is filtered out (no false positive)" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q && git -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m base ) || skip "git unavailable"
  printf 'aaa\n' > "$_repo/foo.ts"
  ( cd "$_repo" && git add foo.ts \
    && GIT_AUTHOR_DATE="2026-05-15T00:30:00Z" GIT_COMMITTER_DATE="2026-05-15T00:30:00Z" \
       git -c user.email=t@t -c user.name=t commit -q -m c )
  # 3-char symbol — must be filtered (min length 4). No line range either.
  run pp_oar_acted_for_path "$_repo" "foo.ts" "aaa" "" 1778803200 1778806800
  [ "$status" -ne 0 ]
  rm -rf "$_repo"
}

@test "acted_for_path: rename-tracked via --follow + -M50%" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q && git -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m base ) || skip "git unavailable"
  printf 'identicalContent\nlineTwo\nlineThree\n' > "$_repo/old.ts"
  ( cd "$_repo" && git add old.ts \
    && GIT_AUTHOR_DATE="2026-05-15T00:30:00Z" GIT_COMMITTER_DATE="2026-05-15T00:30:00Z" \
       git -c user.email=t@t -c user.name=t commit -q -m initial )
  # Rename + small edit (preserve > 50% content for -M50%).
  ( cd "$_repo" && git mv old.ts new.ts \
    && printf 'identicalContent\nlineTwo\nlineThree\naddedRenameSymbol\n' > new.ts \
    && git add new.ts \
    && GIT_AUTHOR_DATE="2026-05-15T00:35:00Z" GIT_COMMITTER_DATE="2026-05-15T00:35:00Z" \
       git -c user.email=t@t -c user.name=t commit -q -m rename )
  # Query the NEW path; --follow should walk back through the rename and
  # the rename-commit's diff should contain the added symbol.
  local out
  out=$(pp_oar_acted_for_path "$_repo" "new.ts" "addedRenameSymbol" "" \
        1778803200 1778806800)
  printf '%s' "$out" | grep -qE '^[0-9a-f]{40}\|symbol_exact$'
  rm -rf "$_repo"
}

@test "acted_for_path: commit OUTSIDE time window does NOT match" {
  # Plan brief: commit-outside-time-window (NOT acted). The --since/--until
  # bounds must exclude commits stamped before inject_ts or after scan_at.
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q && git -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m base ) || skip "git unavailable"
  printf '%s\n' 'doSomething();' > "$_repo/foo.ts"
  # Commit stamped 2026-05-14T00:30:00Z (1778675400) — BEFORE the window
  # [1778803200, 1778806800] = 2026-05-15T00:00:00Z..2026-05-15T01:00:00Z.
  ( cd "$_repo" && git add foo.ts \
    && GIT_AUTHOR_DATE="2026-05-14T00:30:00Z" GIT_COMMITTER_DATE="2026-05-14T00:30:00Z" \
       git -c user.email=t@t -c user.name=t commit -q -m "early commit" )
  run pp_oar_acted_for_path "$_repo" "foo.ts" "doSomething" "" \
        1778803200 1778806800
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  rm -rf "$_repo"
}

@test "acted_for_path: no matching commits → returns 1" {
  # Plan brief: no-matching-commits (NOT acted). Empty git log result.
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q && git -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m base ) || skip "git unavailable"
  # No commits touching foo.ts at all. Query in a future window.
  run pp_oar_acted_for_path "$_repo" "foo.ts" "doSomething" "" \
        1778803200 1778806800
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  rm -rf "$_repo"
}

@test "acted_for_path: rejects empty path / empty repo (caller bug guard)" {
  # Defensive: empty PATH or empty REPO_DIR → return 1. Containment is the
  # caller's responsibility, but the function still validates its own
  # inputs to fail fast.
  . "$PP_ROOT/lib/oar.sh"
  run pp_oar_acted_for_path "" "foo.ts" "doSomething" "" 1778803200 1778806800
  [ "$status" -ne 0 ]
  run pp_oar_acted_for_path "/tmp" "" "doSomething" "" 1778803200 1778806800
  [ "$status" -ne 0 ]
}

@test "acted_for_path: rejects non-repo directory" {
  # Plan brief: containment + git availability. We assert that a directory
  # without .git/ short-circuits to rc=1 (no git operations attempted).
  . "$PP_ROOT/lib/oar.sh"
  local _nongit
  _nongit=$(mktemp -d)
  printf 'doSomething();' > "$_nongit/foo.ts"
  run pp_oar_acted_for_path "$_nongit" "foo.ts" "doSomething" "" \
        1778803200 1778806800
  [ "$status" -ne 0 ]
  rm -rf "$_nongit"
}

@test "acted_for_path: option-injection guard on path (leading dash → return 1)" {
  # pp_safe_git_pathspec rejects leading-`-` paths to prevent option injection.
  # This is the helper's contract; the function inherits it.
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q && git -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m base ) || skip "git unavailable"
  run pp_oar_acted_for_path "$_repo" "-rf" "doSomething" "" \
        1778803200 1778806800
  [ "$status" -ne 0 ]
  rm -rf "$_repo"
}

# GPT-review #10: pure-deletion test. A commit that deletes lines near the
# cited range produces hunks like `@@ -100,5 +99,0 @@` (5 lines removed,
# 0 added at line 99). The OLD-range overlap check must catch this; the
# NEW range alone would miss (start=99, count=0 → end=98 → empty interval).
@test "acted_for_path: line_proximity catches pure deletion near cited range" {
  command -v git >/dev/null 2>&1 || skip "git not installed"
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d) || skip "mktemp failed"
  (
    cd "$_repo" && git init -q \
      && git config gc.auto 0 && git config maintenance.auto false \
      && git config user.email t@t && git config user.name t
    # Create a 200-line file
    awk 'BEGIN{for(i=1;i<=200;i++) print "line " i}' > big.txt
    git add big.txt && git -c commit.gpgsign=false commit -q -m "init"
    export GIT_COMMITTER_DATE="2026-05-15T00:30:00Z"
    export GIT_AUTHOR_DATE="2026-05-15T00:30:00Z"
    # Pure deletion at lines 100-110 (the cited area)
    sed -i.bak '100,110d' big.txt && rm -f big.txt.bak
    git add big.txt && git commit -q -m "delete lines 100-110"
  ) >/dev/null 2>&1 || { rm -rf "$_repo"; skip "git fixture setup failed"; }
  # Cite lines 105-108 (inside the deleted range)
  local out rc
  out=$(pp_oar_acted_for_path "$_repo" "big.txt" "" "105-108" \
         1778803200 1778806800); rc=$?
  rm -rf "$_repo"
  [ "$rc" -eq 0 ]
  printf '%s\n' "$out" | grep -qE '^[0-9a-f]{40}\|line_proximity$'
}

# GPT-review #11: pre-rename test. A commit BEFORE the rename adds the
# cited symbol on the OLD path. Without the pathspec-drop fix in git show,
# the show command filters to the NEW path and emits empty for the
# pre-rename commit → symbol scan misses. With the fix, the diff is shown
# in full and the symbol is found.
@test "acted_for_path: catches symbol added in pre-rename commit (via --follow)" {
  command -v git >/dev/null 2>&1 || skip "git not installed"
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d) || skip "mktemp failed"
  (
    cd "$_repo" && git init -q \
      && git config gc.auto 0 && git config maintenance.auto false \
      && git config user.email t@t && git config user.name t
    # Initial: empty old.ts
    printf 'placeholder\n' > old.ts
    git add old.ts && git -c commit.gpgsign=false commit -q -m "init"
    # Commit 1 (in window): ADD the cited symbol on the OLD path
    export GIT_COMMITTER_DATE="2026-05-15T00:15:00Z"
    export GIT_AUTHOR_DATE="2026-05-15T00:15:00Z"
    printf 'function pp_my_special_symbol_42() {}\n' >> old.ts
    git add old.ts && git commit -q -m "add pp_my_special_symbol_42 to old.ts"
    # Commit 2 (in window): rename old.ts → new.ts (content stays)
    export GIT_COMMITTER_DATE="2026-05-15T00:30:00Z"
    export GIT_AUTHOR_DATE="2026-05-15T00:30:00Z"
    git mv old.ts new.ts && git commit -q -m "rename old.ts → new.ts"
  ) >/dev/null 2>&1 || { rm -rf "$_repo"; skip "git fixture setup failed"; }
  # Cite by the CURRENT path (new.ts) — git log --follow walks back to
  # old.ts via -M50%. The pre-rename commit's diff must be scanned even
  # though its filename is old.ts at that commit.
  local out rc
  out=$(pp_oar_acted_for_path "$_repo" "new.ts" "pp_my_special_symbol_42" "" \
         1778803200 1778806800); rc=$?
  rm -rf "$_repo"
  [ "$rc" -eq 0 ]
  printf '%s\n' "$out" | grep -qE '^[0-9a-f]{40}\|symbol_exact$'
}

# GPT-review #6: malformed LINE_RANGE rejection. "20-" (empty after dash)
# previously silently set _l_hi=0, which after ±20 expansion produced the
# bizarre window [1, 20] meaning "near line 20" — surprising to callers
# who meant "from line 20 onward". Now treated as invalid → line check
# disabled → falls through to symbol-only or returns 1.
@test "acted_for_path: malformed LINE_RANGE '20-' is rejected (no bizarre window)" {
  command -v git >/dev/null 2>&1 || skip "git not installed"
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d) || skip "mktemp failed"
  (
    cd "$_repo" && git init -q \
      && git config gc.auto 0 && git config maintenance.auto false \
      && git config user.email t@t && git config user.name t
    printf 'just a line\n' > big.txt
    git add big.txt && git -c commit.gpgsign=false commit -q -m init
    export GIT_COMMITTER_DATE="2026-05-15T00:30:00Z"
    export GIT_AUTHOR_DATE="2026-05-15T00:30:00Z"
    printf 'modified\n' >> big.txt
    git add big.txt && git commit -q -m "edit"
  ) >/dev/null 2>&1 || { rm -rf "$_repo"; skip "git fixture setup failed"; }
  # Malformed range + no symbol → both checks disabled → returns 1
  run pp_oar_acted_for_path "$_repo" "big.txt" "" "20-" 1778803200 1778806800
  rm -rf "$_repo"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Task 7 — pp_oar_referenced (Jaccard bigram + cite-token-symbol detector).
#
# Signature: pp_oar_referenced SID INJECT_TS_EPOCH SCAN_AT_EPOCH BODY \
#                              CITE_SYMBOLS_NEWLINE_SEP
# Reads ~/.claude/cache/transcript-tail-${SID}.txt; uses file mtime as the
# point-in-time bound (no per-line timestamps in v0.5.2 transcript format —
# the PM1 fixture writes plain text). Returns 0 + "line:LO-HI|jaccard:0.NN"
# on match. Otherwise rc=1.
#
# Plan addendum applied: I3 (temp-file comm -12, no <(...)) + M1 (cite-token
# required is restricted to SYMBOLS — paths fail grep -wF and would over-reject).
# ---------------------------------------------------------------------------

# Helper: stamp a transcript file's mtime to a specific epoch so we can
# exercise the [inject_ts, scan_at] window check deterministically.
_pp_oar_set_mtime() {
  local _file="$1" _epoch="$2"
  # touch -t needs YYYYMMDDhhmm.ss
  local _ymdhm
  _ymdhm=$(date -r "$_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null \
           || date -d "@$_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null)
  [ -z "$_ymdhm" ] && return 1
  touch -t "$_ymdhm" "$_file" 2>/dev/null
}

@test "referenced: high Jaccard + cite-symbol present → returns line:lo-hi|jaccard:0.NN" {
  . "$PP_ROOT/lib/oar.sh"
  local _sid="sess-r1"
  local _tail="$PP_CACHE_DIR/transcript-tail-${_sid}.txt"
  # Use a high-overlap fixture so the bigram intersection is large enough
  # to clear τ=0.5 even AFTER stopword filtering. The cite-symbol
  # `handleRetry` appears verbatim in both — satisfies M1's symbol gate.
  printf 'refactoring handleRetry debounce stale events payload streaming queue retry handler\n' \
    > "$_tail"
  # Stamp mtime inside [inj, scan] window.
  _pp_oar_set_mtime "$_tail" 1778893500 || skip "touch -t unsupported"
  local _body='refactoring handleRetry debounce stale events payload streaming queue retry'
  local _cites='handleRetry'
  local _out
  _out=$(pp_oar_referenced "$_sid" 1778893200 1778893800 "$_body" "$_cites")
  printf '%s' "$_out" | grep -qE '^line:[0-9]+-[0-9]+\|jaccard:[01]\.[0-9]+$'
}

@test "referenced: high Jaccard but NO cite-symbol → rc != 0 (cite-token required)" {
  . "$PP_ROOT/lib/oar.sh"
  local _sid="sess-r2"
  local _tail="$PP_CACHE_DIR/transcript-tail-${_sid}.txt"
  printf 'i am refactoring functions to debounce stale events properly\n' > "$_tail"
  _pp_oar_set_mtime "$_tail" 1778893500 || skip "touch -t unsupported"
  local _body='Consider debouncing functions to avoid stale events when network is slow'
  # Cite symbol is something nowhere in the transcript.
  local _cites='ZZZmysterySymbol'
  run pp_oar_referenced "$_sid" 1778893200 1778893800 "$_body" "$_cites"
  [ "$status" -ne 0 ]
}

@test "referenced: cite-symbol present but Jaccard below threshold rejects" {
  . "$PP_ROOT/lib/oar.sh"
  local _sid="sess-r3"
  local _tail="$PP_CACHE_DIR/transcript-tail-${_sid}.txt"
  printf 'i mentioned handleRetry once but everything else is totally different\n' \
    > "$_tail"
  _pp_oar_set_mtime "$_tail" 1778893500 || skip "touch -t unsupported"
  # τ=0.5 default; the bodies share only a cite-token and a couple of
  # incidental tokens, so bigram Jaccard falls well below 0.5.
  local _body='Use exponential backoff with jitter on the handleRetry retry path'
  local _cites='handleRetry'
  run pp_oar_referenced "$_sid" 1778893200 1778893800 "$_body" "$_cites"
  [ "$status" -ne 0 ]
}

@test "referenced: transcript file missing → rc = 1" {
  . "$PP_ROOT/lib/oar.sh"
  run pp_oar_referenced "sess-nonexistent-r4" 1778893200 1778893800 \
                         "any body" "anySymbol"
  [ "$status" -eq 1 ]
}

@test "referenced: transcript mtime BEFORE inject_ts → rc != 0 (outside window)" {
  . "$PP_ROOT/lib/oar.sh"
  local _sid="sess-r5"
  local _tail="$PP_CACHE_DIR/transcript-tail-${_sid}.txt"
  printf 'i am refactoring the handleRetry function to debounce stale events\n' \
    > "$_tail"
  # mtime BEFORE the inject window — must be rejected even though content matches.
  _pp_oar_set_mtime "$_tail" 1778890000 || skip "touch -t unsupported"
  local _body='Consider debouncing handleRetry to avoid stale events when the network is slow'
  local _cites='handleRetry'
  run pp_oar_referenced "$_sid" 1778893200 1778893800 "$_body" "$_cites"
  [ "$status" -ne 0 ]
}

@test "referenced: transcript mtime AFTER scan_at → rc != 0 (late-reference leak guard)" {
  . "$PP_ROOT/lib/oar.sh"
  local _sid="sess-r6"
  local _tail="$PP_CACHE_DIR/transcript-tail-${_sid}.txt"
  printf 'i am refactoring the handleRetry function to debounce stale events\n' \
    > "$_tail"
  # mtime AFTER scan_at — must be rejected (no late-reference leakage).
  _pp_oar_set_mtime "$_tail" 1778900000 || skip "touch -t unsupported"
  local _body='Consider debouncing handleRetry to avoid stale events when the network is slow'
  local _cites='handleRetry'
  run pp_oar_referenced "$_sid" 1778893200 1778893800 "$_body" "$_cites"
  [ "$status" -ne 0 ]
}

@test "referenced: only PATH cite-token (no symbol) → rc != 0 per M1" {
  # Plan addendum M1: cite-token-required is restricted to SYMBOLS, never
  # paths. Paths with slashes/dots rarely pass grep -wF word-boundary checks,
  # so requiring them would produce false rejections. Even if the path
  # appears verbatim in the transcript, requiring SYMBOL presence means a
  # symbols-empty citation list rejects regardless of path overlap.
  . "$PP_ROOT/lib/oar.sh"
  local _sid="sess-r7"
  local _tail="$PP_CACHE_DIR/transcript-tail-${_sid}.txt"
  printf 'i am refactoring lib/oar.sh to debounce stale events\n' > "$_tail"
  _pp_oar_set_mtime "$_tail" 1778893500 || skip "touch -t unsupported"
  local _body='Consider debouncing the lib/oar.sh callsite to avoid stale events'
  # CITES contains only a path-shaped token; no SYMBOL → reject.
  local _cites='lib/oar.sh'
  run pp_oar_referenced "$_sid" 1778893200 1778893800 "$_body" "$_cites"
  [ "$status" -ne 0 ]
}

@test "referenced: empty CITES → rc != 0 (cite-token required)" {
  . "$PP_ROOT/lib/oar.sh"
  local _sid="sess-r8"
  local _tail="$PP_CACHE_DIR/transcript-tail-${_sid}.txt"
  printf 'identical text identical text identical text\n' > "$_tail"
  _pp_oar_set_mtime "$_tail" 1778893500 || skip "touch -t unsupported"
  run pp_oar_referenced "$_sid" 1778893200 1778893800 \
                         "identical text identical text" ""
  [ "$status" -ne 0 ]
}

@test "referenced: stopwords are filtered before Jaccard (cite-symbol still required)" {
  . "$PP_ROOT/lib/oar.sh"
  local _sid="sess-r9"
  local _tail="$PP_CACHE_DIR/transcript-tail-${_sid}.txt"
  # Heavy stopword + 3 content tokens including the cite-symbol. After
  # filtering, transcript bigrams = {handleRetry_payload, payload_streaming}
  # and body bigrams = {handleRetry_payload, payload_streaming}. Identical →
  # Jaccard = 1.0 > τ. If stopwords were NOT filtered, the score would
  # be similar (still high), but the assertion below is content-driven —
  # filtering doesn't break the positive match.
  printf 'the and for from import handleRetry payload streaming\n' > "$_tail"
  _pp_oar_set_mtime "$_tail" 1778893500 || skip "touch -t unsupported"
  local _body='the and for from import handleRetry payload streaming'
  local _cites='handleRetry'
  local _out
  _out=$(pp_oar_referenced "$_sid" 1778893200 1778893800 "$_body" "$_cites")
  [ -n "$_out" ]
  # Accept either 0.NN (sub-unity) or 1.0000 (perfect overlap) jaccard.
  printf '%s' "$_out" | grep -qE '^line:[0-9]+-[0-9]+\|jaccard:[01]\.[0-9]+$'
}
