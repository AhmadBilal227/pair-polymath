#!/usr/bin/env bats
# v0.5.2 — Hallucination gate post-check (shadow mode).
# Spec: docs/v0.5.2-oar-hallucination-spec.md §C
# Plan: docs/superpowers/plans/2026-05-15-v0.5.2-oar-hallucination.md Task 9
#
# Function under test: pp_halluc_verify_citations CWD BODY PATHS_NL SYMS_NL
#   rc=0  → all citations verify (would-PASS)
#   rc=1  → at least one citation fails strict check (would-DROP)
#
# Contract: pure. NO globals mutated, NO files written, NO verdict flip.
# The caller decides whether to ACT on the rc=1 (only when
# PP_HALLUC_GATE_ACTIVE=1, wired in Task 12). v0.5.2 is shadow-only.

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
  unset PP_HALLUC_GATE_DEEP PP_HALLUC_GATE_ENABLE PP_HALLUC_GATE_ACTIVE
}

teardown() {
  rm -rf "$HOME"
}

@test "halluc: empty inputs (no citations) → rc=0 trivially" {
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  run pp_halluc_verify_citations "$_repo" "general advisory body" "" ""
  [ "$status" -eq 0 ]
  rm -rf "$_repo"
}

@test "halluc: cited path that exists in cwd → rc=0 (would-pass)" {
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  ( cd "$_repo" && touch real.ts )
  run pp_halluc_verify_citations "$_repo" \
      "Refactor real.ts to handle errors" "real.ts" ""
  [ "$status" -eq 0 ]
  rm -rf "$_repo"
}

@test "halluc: cited path NOT on disk → rc=1 (would-drop)" {
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  run pp_halluc_verify_citations "$_repo" \
      "Refactor fake-file.ts to handle errors" "fake-file.ts" ""
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "halluc: cited symbol present (word-boundary) in file → rc=0" {
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  printf 'function handleRetry() {}\n' > "$_repo/a.ts"
  run pp_halluc_verify_citations "$_repo" \
      "Replace handleRetry with exponential backoff" "a.ts" "handleRetry"
  [ "$status" -eq 0 ]
  rm -rf "$_repo"
}

@test "halluc: cited symbol NOT present in any cited file → rc=1" {
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  printf 'function handleRetry() {}\n' > "$_repo/a.ts"
  run pp_halluc_verify_citations "$_repo" \
      "Replace nonExistentSymbol" "a.ts" "nonExistentSymbol"
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "halluc: path traversal (escapes cwd) is rejected via pp_contain_path" {
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  run pp_halluc_verify_citations "$_repo" \
      "Edit /etc/passwd" "../../etc/passwd" ""
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "halluc: symbol substring (no word boundary) does NOT count" {
  # Stricter than basename-collapse — must be a real token match.
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  # "handleRetryQueueDispatcher" contains "handleRetry" as a substring
  # but NOT as a word-boundary token.
  printf 'function handleRetryQueueDispatcher() {}\n' > "$_repo/a.ts"
  run pp_halluc_verify_citations "$_repo" \
      "Replace handleRetry" "a.ts" "handleRetry"
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "halluc: symbol shorter than min-token-length (4) → rc=1" {
  # Matches spec §B's stopword min length 4 (post-check is stricter,
  # not laxer, than acted check).
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  printf 'var x = 1;\n' > "$_repo/a.ts"
  run pp_halluc_verify_citations "$_repo" "Edit x" "a.ts" "x"
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "halluc: multiple paths — all must verify (one missing → rc=1)" {
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  touch "$_repo/a.ts"
  # b.ts is fabricated.
  run pp_halluc_verify_citations "$_repo" "Touch both" "$(printf 'a.ts\nb.ts')" ""
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "halluc: multiple symbols — all must verify (one missing → rc=1)" {
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  printf 'function realSymbol() {}\n' > "$_repo/a.ts"
  run pp_halluc_verify_citations "$_repo" "x" "a.ts" \
      "$(printf 'realSymbol\nfakeSymbol')"
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "halluc: DEEP=1 ctags fallback resolves symbol not in cited file scan" {
  if ! command -v ctags >/dev/null 2>&1; then
    skip "ctags not on PATH"
  fi
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  printf 'function defineMe() {}\n' > "$_repo/code.ts"
  ( cd "$_repo" && ctags -R --fields=+n -f tags . 2>/dev/null ) || skip "ctags exec failed"
  [ -s "$_repo/tags" ] || skip "ctags produced empty tags file"
  # No cited path containing defineMe; DEEP=1 → consults tags index.
  PP_HALLUC_GATE_DEEP=1 run pp_halluc_verify_citations \
      "$_repo" "Use defineMe" "" "defineMe"
  [ "$status" -eq 0 ]
  rm -rf "$_repo"
}

@test "halluc: DEEP=0 does NOT consult ctags (predictable shadow baseline)" {
  if ! command -v ctags >/dev/null 2>&1; then
    skip "ctags not on PATH"
  fi
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  printf 'function defineMe() {}\n' > "$_repo/code.ts"
  ( cd "$_repo" && ctags -R --fields=+n -f tags . 2>/dev/null ) || skip "ctags exec failed"
  # No cited path; DEEP=0 → must NOT fall back to tags.
  PP_HALLUC_GATE_DEEP=0 run pp_halluc_verify_citations \
      "$_repo" "Use defineMe" "" "defineMe"
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "halluc: DEEP=1 gracefully degrades when no tags file present" {
  . "$PP_ROOT/lib/hallucination.sh"
  local _repo
  _repo=$(mktemp -d)
  # No tags file. DEEP=1 doesn't magically find unknown symbols.
  PP_HALLUC_GATE_DEEP=1 run pp_halluc_verify_citations \
      "$_repo" "Use someSymbol" "" "someSymbol"
  [ "$status" -eq 1 ]
  rm -rf "$_repo"
}

@test "halluc: shadow contract — function does NOT mutate PP_VERDICT / write files" {
  # Library contract assertion: the function body must not touch any
  # observable verdict-state surface. This protects the OAR denominator
  # (spec §C "Critical change from v2"). Inspect the function source.
  #
  # Task-9 review (code-reviewer P2 + GPT #10): the earlier regex missed
  # single `>` redirects, `cp`/`mv`/`rm`, `eval`, and `command sub > path`
  # patterns. Tightened to catch the full write surface.
  . "$PP_ROOT/lib/hallucination.sh"
  local _src
  _src=$(declare -f pp_halluc_verify_citations)
  ! printf '%s\n' "$_src" | LC_ALL=C grep -E 'PP_VERDICT|verdict=|verdict_file' >/dev/null
  # Write surfaces — must NOT appear in the function body. Note: the test
  # uses anchored patterns so common reads (e.g. `< file`) don't fire.
  # The function is allowed to use READ stdin redirection ( `<` ) and
  # process substitution; what it cannot do is WRITE.
  ! printf '%s\n' "$_src" | LC_ALL=C grep -E '>>|tee | mktemp' >/dev/null
  # Single `>` redirect (excluding `>=`, `>&` and `>/dev/null`-style
  # discards which we tolerate as no-op writes). Empirically detect the
  # WRITE TO A NAMED PATH form: ` > /` or ` > $`, which would be a real
  # external write.
  ! printf '%s\n' "$_src" | LC_ALL=C grep -E ' > /|> \$|> [a-z]' >/dev/null
  # Mutating shell commands.
  ! printf '%s\n' "$_src" | LC_ALL=C grep -E ' (cp|mv|rm) |eval ' >/dev/null
}

@test "halluc: missing cwd dir → rc=1" {
  . "$PP_ROOT/lib/hallucination.sh"
  run pp_halluc_verify_citations "/does/not/exist" "x" "a.ts" ""
  [ "$status" -eq 1 ]
}
