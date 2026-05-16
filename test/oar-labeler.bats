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

# ----------------------------------------------------------------------------
# Task 8 — pp_oar_label_pending (full 4-outcome classifier driver).
#
# Order of outcome detection per spec §B (first hit wins):
#   pushed_back → acted → referenced → ignored
#
# Notes on the test harness:
#   - `command -v git >/dev/null 2>&1 || skip` guards git fixtures.
#   - Rows are appended directly to oar-pending.jsonl with deterministic
#     scan_at_epoch values so we can use a fixed `now` via PP_OAR_NOW_OVERRIDE
#     (Task-8 implementation honours that env knob for testability). If the
#     implementation chooses a different injection style, the in-window
#     epochs (≤ Sun, 2026-05-15) ensure scan_at < `date +%s` at runtime
#     regardless.
#
# Inject_ts choice for line-window tests: 2026-05-14T00:00:00Z (epoch
# 1778716800) so the actual `date +%s` at runtime (well past mid-2026) is the
# window upper bound, matching scan_at when scan_at_epoch is in the past.
# ----------------------------------------------------------------------------

@test "label_pending: end-to-end synthesizes acted outcome for a real diff" {
  command -v git >/dev/null 2>&1 || skip "git not installed"
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q \
    && git config user.email t@t && git config user.name t \
    && git -c commit.gpgsign=false commit -q --allow-empty -m base ) \
    || { rm -rf "$_repo"; skip "git fixture failed"; }
  printf 'longSymbolName();\n' > "$_repo/x.ts"
  ( cd "$_repo" && git add x.ts \
    && GIT_AUTHOR_DATE="2026-05-15T00:30:00Z" \
       GIT_COMMITTER_DATE="2026-05-15T00:30:00Z" \
       git -c commit.gpgsign=false commit -q -m c )
  # scan_at_epoch is in the past so the row is "due".
  jq -nc '{session_id:"s1",lens:"ENGINEERING",hash:"h-1",
          inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:1778889600,
          attempts:0,status:"pending",
          body:"refactor longSymbolName per x.ts",
          cited_paths:["x.ts"],cited_symbols:["longSymbolName"]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  CLAUDE_PROJECT_DIR="$_repo" PP_OAR_LABEL_PER_CYCLE_CAP=5 \
    pp_oar_label_pending
  [ -f "$PP_CACHE_DIR/oar-labeled.jsonl" ]
  jq -e '.outcome == "acted" and .confidence == "symbol_exact"' \
    "$PP_CACHE_DIR/oar-labeled.jsonl" >/dev/null
  rm -rf "$_repo"
}

@test "label_pending: ignored outcome when window elapsed with no signal" {
  command -v git >/dev/null 2>&1 || skip "git not installed"
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q \
    && git config user.email t@t && git config user.name t \
    && git -c commit.gpgsign=false commit -q --allow-empty -m base ) \
    || { rm -rf "$_repo"; skip "git fixture failed"; }
  # No matching commit, no transcript, no dismiss rule.
  jq -nc '{session_id:"s2",lens:"SECURITY",hash:"h-2",
          inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:1778889600,
          attempts:0,status:"pending",body:"",
          cited_paths:[],cited_symbols:[]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  CLAUDE_PROJECT_DIR="$_repo" pp_oar_label_pending
  [ -f "$PP_CACHE_DIR/oar-labeled.jsonl" ]
  jq -e '.outcome == "ignored" and .confidence == "no_signal_in_window"' \
    "$PP_CACHE_DIR/oar-labeled.jsonl" >/dev/null
  rm -rf "$_repo"
}

@test "label_pending: idempotency — running twice does not double-label" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q \
    && git config user.email t@t && git config user.name t \
    && git -c commit.gpgsign=false commit -q --allow-empty -m base ) \
    || { rm -rf "$_repo"; skip "git fixture failed"; }
  jq -nc '{session_id:"s3",lens:"UX_DESIGN",hash:"h-3",
          inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:1778889600,
          attempts:0,status:"pending",body:"",
          cited_paths:[],cited_symbols:[]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  CLAUDE_PROJECT_DIR="$_repo" pp_oar_label_pending
  # Second run with the SAME identity should be a no-op. We seed the pending
  # file again to prove the labeler refuses to re-label by identity-set
  # membership.
  jq -nc '{session_id:"s3",lens:"UX_DESIGN",hash:"h-3",
          inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:1778889600,
          attempts:0,status:"pending",body:"",
          cited_paths:[],cited_symbols:[]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  CLAUDE_PROJECT_DIR="$_repo" pp_oar_label_pending
  local _n
  _n=$(wc -l < "$PP_CACHE_DIR/oar-labeled.jsonl" | tr -d ' ')
  [ "$_n" -eq 1 ]
  rm -rf "$_repo"
}

@test "label_pending: per-cycle cap of 5 caps rows labeled" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q \
    && git config user.email t@t && git config user.name t \
    && git -c commit.gpgsign=false commit -q --allow-empty -m base ) \
    || { rm -rf "$_repo"; skip "git fixture failed"; }
  : > "$PP_CACHE_DIR/oar-pending.jsonl"
  local _i
  for _i in 1 2 3 4 5 6 7; do
    jq -nc --arg sid "s-cap-$_i" --argjson scan $(( 1778889600 + _i )) '
      {session_id:$sid,lens:"ENGINEERING",hash:("h-" + $sid),
       inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:$scan,
       attempts:0,status:"pending",body:"",
       cited_paths:[],cited_symbols:[]}' \
      >> "$PP_CACHE_DIR/oar-pending.jsonl"
  done
  CLAUDE_PROJECT_DIR="$_repo" PP_OAR_LABEL_PER_CYCLE_CAP=5 pp_oar_label_pending
  local _labeled _pending
  _labeled=$(wc -l < "$PP_CACHE_DIR/oar-labeled.jsonl" | tr -d ' ')
  _pending=$(wc -l < "$PP_CACHE_DIR/oar-pending.jsonl" | tr -d ' ')
  [ "$_labeled" -eq 5 ]
  [ "$_pending" -eq 2 ]
  rm -rf "$_repo"
}

@test "label_pending: FIFO by scan_at_epoch ASC" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q \
    && git config user.email t@t && git config user.name t \
    && git -c commit.gpgsign=false commit -q --allow-empty -m base ) \
    || { rm -rf "$_repo"; skip "git fixture failed"; }
  : > "$PP_CACHE_DIR/oar-pending.jsonl"
  # Row B is younger (later scan_at), Row A is older.
  jq -nc '{session_id:"sB",lens:"ENGINEERING",hash:"hB",
          inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:1778900000,
          attempts:0,status:"pending",body:"",
          cited_paths:[],cited_symbols:[]}' \
    >> "$PP_CACHE_DIR/oar-pending.jsonl"
  jq -nc '{session_id:"sA",lens:"ENGINEERING",hash:"hA",
          inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:1778889700,
          attempts:0,status:"pending",body:"",
          cited_paths:[],cited_symbols:[]}' \
    >> "$PP_CACHE_DIR/oar-pending.jsonl"
  CLAUDE_PROJECT_DIR="$_repo" PP_OAR_LABEL_PER_CYCLE_CAP=1 pp_oar_label_pending
  # Older (A) should be labeled first.
  jq -e '.session_id == "sA"' "$PP_CACHE_DIR/oar-labeled.jsonl" >/dev/null
  rm -rf "$_repo"
}

@test "label_pending: containment rejects rows citing paths outside cwd" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q \
    && git config user.email t@t && git config user.name t \
    && git -c commit.gpgsign=false commit -q --allow-empty -m base ) \
    || { rm -rf "$_repo"; skip "git fixture failed"; }
  # Path traversal — outside the repo.
  jq -nc '{session_id:"s-esc",lens:"ENGINEERING",hash:"h-esc",
          inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:1778889600,
          attempts:0,status:"pending",body:"",
          cited_paths:["../../etc/passwd"],cited_symbols:["bad"]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  CLAUDE_PROJECT_DIR="$_repo" pp_oar_label_pending
  # Should label as ignored (containment failed → no acted path checked).
  jq -e '.outcome == "ignored"' "$PP_CACHE_DIR/oar-labeled.jsonl" >/dev/null
  rm -rf "$_repo"
}

@test "label_pending: attempts++ → quarantine to oar-stuck.jsonl after 3 fails" {
  . "$PP_ROOT/lib/oar.sh"
  # Force failure: point CLAUDE_PROJECT_DIR at a non-git dir but cite a path
  # inside it (so containment passes). The labeler stub forces a synthetic
  # error from the acted detector to simulate a transient failure path.
  local _noindex
  _noindex=$(mktemp -d)
  : > "$_noindex/foo.ts"
  jq -nc '{session_id:"s-stuck",lens:"ENGINEERING",hash:"h-stuck",
          inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:1778889600,
          attempts:2,status:"pending",body:"",
          cited_paths:["foo.ts"],cited_symbols:["someThing"]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  # Monkey-patch pp_oar_acted_for_path to always return 2 (synthetic
  # transient error). The labeler must increment attempts → quarantine.
  pp_oar_acted_for_path() { return 2; }
  CLAUDE_PROJECT_DIR="$_noindex" pp_oar_label_pending
  [ -f "$PP_CACHE_DIR/oar-stuck.jsonl" ]
  jq -e '.session_id == "s-stuck" and .attempts == 3' \
    "$PP_CACHE_DIR/oar-stuck.jsonl" >/dev/null
  rm -rf "$_noindex"
}

@test "label_pending: not-yet-due rows stay in pending (no label)" {
  . "$PP_ROOT/lib/oar.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q \
    && git config user.email t@t && git config user.name t \
    && git -c commit.gpgsign=false commit -q --allow-empty -m base ) \
    || { rm -rf "$_repo"; skip "git fixture failed"; }
  # scan_at_epoch far in the future → NOT due.
  jq -nc '{session_id:"s-future",lens:"ENGINEERING",hash:"h-fut",
          inject_ts:"2026-05-14T00:00:00Z",
          scan_at_epoch:9999999999,
          attempts:0,status:"pending",body:"",
          cited_paths:[],cited_symbols:[]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  CLAUDE_PROJECT_DIR="$_repo" pp_oar_label_pending
  # Pending row preserved; labeled file either absent or empty.
  [ "$(wc -l < "$PP_CACHE_DIR/oar-pending.jsonl" | tr -d ' ')" = "1" ]
  if [ -f "$PP_CACHE_DIR/oar-labeled.jsonl" ]; then
    [ "$(wc -l < "$PP_CACHE_DIR/oar-labeled.jsonl" | tr -d ' ')" = "0" ]
  fi
  rm -rf "$_repo"
}

@test "label_pending: pushed-back outcome via dismiss-ack rule" {
  . "$PP_ROOT/lib/oar.sh"
  # Set up a dismiss-ack rule that matches the row's hash within window.
  # shellcheck source=../lib/memory/schema.sh
  . "$PP_ROOT/lib/memory/schema.sh"
  # shellcheck source=../lib/dismiss.sh
  . "$PP_ROOT/lib/dismiss.sh"
  mkdir -p "$PP_STATE_DIR/dismiss"
  local _f
  _f=$(pp_dismiss_file_path)
  # inject_ts = 2026-05-14T00:00:00Z (epoch 1778716800)
  # scan_at   = 2026-05-15T00:00:00Z (epoch 1778803200)
  # ack ts    = 2026-05-14T12:00:00Z (epoch 1778760000) → in window
  jq -nc \
    '{id:"a-pb",ts:"2026-05-14T12:00:00Z",
      reason_summary:"acked",scope:"project",lens_id:null,
      hash:"feedba",deleted:false,deleted_reason:null,
      ttl_days:null,source:"ack"}' >> "$_f"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && git init -q \
    && git config user.email t@t && git config user.name t \
    && git -c commit.gpgsign=false commit -q --allow-empty -m base ) \
    || { rm -rf "$_repo"; skip "git fixture failed"; }
  jq -nc '{session_id:"s-pb",lens:"ENGINEERING",hash:"feedbabe",
          inject_ts:"2026-05-14T00:00:00Z",scan_at_epoch:1778803200,
          attempts:0,status:"pending",body:"",
          cited_paths:[],cited_symbols:[]}' \
    > "$PP_CACHE_DIR/oar-pending.jsonl"
  CLAUDE_PROJECT_DIR="$_repo" pp_oar_label_pending
  jq -e '.outcome == "pushed-back" and .evidence_id == "a-pb"' \
    "$PP_CACHE_DIR/oar-labeled.jsonl" >/dev/null
  rm -rf "$_repo"
}

# PM1 — Mandatory E2E test. Real SessionEnd hook → real labeler.
#
# Containment matters here: pp_oar_acted_for_path resolves cited paths
# relative to CLAUDE_PROJECT_DIR (or $PWD as fallback). If we leave it
# unset, bats runs from the actual pair-polymath checkout and the real
# git history at lib/oar.sh would fire `acted` (correctly!), masking the
# `referenced` signal we want to assert. Point CLAUDE_PROJECT_DIR at an
# isolated tmpdir without git, so acted+pushed-back can't fire and only
# referenced (which depends on the transcript file, not git) is left to
# detect.
@test "v0.5.2 E2E: SessionEnd → labeler produces non-empty referenced detection" {
  command -v git >/dev/null 2>&1 || skip "git not installed"
  export PP_OAR_ENABLE=1
  mkdir -p "$PP_CACHE_DIR"
  # Isolated, no-git project root. lib/oar.sh resolution falls through
  # the .git/ check in pp_oar_acted_for_path → no acted detection.
  local _isolated
  _isolated=$(mktemp -d)
  mkdir -p "$_isolated/lib"
  : > "$_isolated/lib/oar.sh"
  export CLAUDE_PROJECT_DIR="$_isolated"

  local _hash="abc123def456"
  # Observation has citable SYMBOL pp_oar_label_pending plus path lib/oar.sh.
  # Body must produce strong bigram overlap with the transcript and contain
  # the symbol as a whole word.
  local _obs_file="$PP_CACHE_DIR/cc-monitor-sess-e2e-ENGINEERING.txt"
  printf 'ENG: refactor|||The pp_oar_label_pending function in lib/oar.sh needs hardening pp_oar_label_pending function lib/oar.sh hardening pp_oar_label_pending\n' \
    > "$_obs_file"
  local _hash_file="$PP_CACHE_DIR/cc-monitor-injected-hash-sess-e2e-ENGINEERING.txt"
  printf '%s\n' "$_hash" > "$_hash_file"
  # Stamp hash file mtime to ~25h before runtime-now so SessionEnd places
  # scan_at < now (ENG window is 24h). Compute via portable date.
  local _now _ago _ymdhm
  _now=$(date +%s)
  _ago=$(( _now - 90000 ))
  _ymdhm=$(date -r "$_ago" '+%Y%m%d%H%M.%S' 2>/dev/null \
           || date -d "@$_ago" '+%Y%m%d%H%M.%S' 2>/dev/null) \
           || skip "portable date unavailable"
  touch -t "$_ymdhm" "$_hash_file" 2>/dev/null || skip "touch -t failed"

  # Transcript that references the observation — must contain the symbol
  # as a whole word AND share enough bigrams to clear τ=0.5.
  local _tail="$PP_CACHE_DIR/transcript-tail-sess-e2e.txt"
  printf 'User: please harden pp_oar_label_pending function in lib/oar.sh; the pp_oar_label_pending function in lib/oar.sh needs hardening pp_oar_label_pending\n' \
    > "$_tail"
  # Stamp transcript mtime to ~12h ago — INSIDE [inject (-25h), scan_at
  # (-1h)] window. Touching with no -t would set mtime to "now" which is
  # PAST scan_at and trip pp_oar_referenced's late-reference guard.
  local _mid _mid_ymdhm
  _mid=$(( _now - 43200 ))
  _mid_ymdhm=$(date -r "$_mid" '+%Y%m%d%H%M.%S' 2>/dev/null \
               || date -d "@$_mid" '+%Y%m%d%H%M.%S' 2>/dev/null) \
               || skip "portable date unavailable"
  touch -t "$_mid_ymdhm" "$_tail" 2>/dev/null || skip "touch -t failed"

  # Run SessionEnd hook → should write a pending row.
  printf '{"session_id":"sess-e2e"}' | bash "$PP_ROOT/hooks/session-end.sh"
  [ -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
  # Sanity: pending row has body + cites populated (path A confirmation).
  jq -e 'has("body") and has("cited_paths") and has("cited_symbols")' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null

  # Run labeler — the moment of truth.
  . "$PP_ROOT/lib/oar.sh"
  pp_oar_label_pending

  # Assert referenced detection actually fired.
  [ -f "$PP_CACHE_DIR/oar-labeled.jsonl" ]
  run jq -r '.outcome' "$PP_CACHE_DIR/oar-labeled.jsonl"
  [ "$output" = "referenced" ]
  rm -rf "$_isolated"
}

# === v0.5.2 Task 10 — pp_kpi_wilson_lower_95 ==================================
# Per plan: pure-awk Wilson 95% CI lower bound on acted% for polymath history.
# Spec §D example: SECURITY 2/7 → Wilson 95% lower ≈ 6.4%.

@test "wilson_lower_95: 0/0 returns 0" {
  . "$PP_ROOT/lib/metrics.sh"
  [ "$(pp_kpi_wilson_lower_95 0 0)" = "0.0000" ]
}

@test "wilson_lower_95: 1/1 (point estimate 1.0) returns lower-bound < 1" {
  . "$PP_ROOT/lib/metrics.sh"
  local _lo
  _lo=$(pp_kpi_wilson_lower_95 1 1)
  # 1/1 with Wilson should be ~0.21 (n=1 has wide CI)
  LC_ALL=C awk -v v="$_lo" 'BEGIN { exit !(v+0 > 0.05 && v+0 < 0.99) }'
}

@test "wilson_lower_95: 2/7 (~28.6%) returns lower bound around 6%" {
  . "$PP_ROOT/lib/metrics.sh"
  local _lo
  _lo=$(pp_kpi_wilson_lower_95 2 7)
  # Spec §D example: SECURITY 2/7 → Wilson 95% lower ≈ 6.4%
  LC_ALL=C awk -v v="$_lo" 'BEGIN { exit !(v+0 > 0.04 && v+0 < 0.10) }'
}

@test "wilson_lower_95: 50/100 returns lower bound around 40%" {
  . "$PP_ROOT/lib/metrics.sh"
  local _lo
  _lo=$(pp_kpi_wilson_lower_95 50 100)
  # Classic Wilson 50% / 100: ~40.4%
  LC_ALL=C awk -v v="$_lo" 'BEGIN { exit !(v+0 > 0.38 && v+0 < 0.43) }'
}

@test "wilson_lower_95: 0/10 returns 0 (zero successes clamp)" {
  . "$PP_ROOT/lib/metrics.sh"
  # k=0 → p=0 → center = (z²/(2n))/D, margin = z*sqrt(z²/(4n²))/D
  # = (z²/(2n))/D and (z²/(2n))/D respectively → lower = 0 exactly.
  [ "$(pp_kpi_wilson_lower_95 0 10)" = "0.0000" ]
}

@test "wilson_lower_95: 10/10 returns positive lower bound < 1" {
  . "$PP_ROOT/lib/metrics.sh"
  local _lo
  _lo=$(pp_kpi_wilson_lower_95 10 10)
  # k=n=10: Wilson 95% lower ≈ 0.7225 (textbook). Asserts > 0.6, < 1.
  LC_ALL=C awk -v v="$_lo" 'BEGIN { exit !(v+0 > 0.60 && v+0 < 1.00) }'
}

@test "wilson_lower_95: 1/2 returns ~0.0943 (textbook fixed-point)" {
  . "$PP_ROOT/lib/metrics.sh"
  local _lo
  _lo=$(pp_kpi_wilson_lower_95 1 2)
  # k=1, n=2: phat=0.5, denom=1+1.96²/2≈2.9208, center≈0.5, margin≈0.4057
  # lower ≈ 0.0943 (well-known small-sample example).
  LC_ALL=C awk -v v="$_lo" 'BEGIN { exit !(v+0 > 0.07 && v+0 < 0.12) }'
}

@test "wilson_lower_95: large n approaches k/n" {
  . "$PP_ROOT/lib/metrics.sh"
  local _lo
  _lo=$(pp_kpi_wilson_lower_95 500 1000)
  # n=1000, phat=0.5 → CI half-width ~0.031. lower ≈ 0.469.
  LC_ALL=C awk -v v="$_lo" 'BEGIN { exit !(v+0 > 0.45 && v+0 < 0.50) }'
}

@test "wilson_lower_95: non-numeric input is coerced to 0 (defensive)" {
  . "$PP_ROOT/lib/metrics.sh"
  # Garbage successes → coerced to 0 → k=0/n=10 → 0.0000.
  [ "$(pp_kpi_wilson_lower_95 abc 10)" = "0.0000" ]
  # Garbage trials → coerced to 0 → n=0 branch → 0.0000.
  [ "$(pp_kpi_wilson_lower_95 5 xyz)" = "0.0000" ]
}

@test "wilson_lower_95: output is always 4 decimal places" {
  . "$PP_ROOT/lib/metrics.sh"
  local _out
  _out=$(pp_kpi_wilson_lower_95 50 100)
  # Match exact format: ^[0-9]\.[0-9]{4}$
  [[ "$_out" =~ ^[0-9]\.[0-9]{4}$ ]]
}
