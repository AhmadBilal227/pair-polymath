#!/usr/bin/env bats
# v0.5.2 — pp_safe_git_pathspec coverage.
#
# Contract (C1 from plan addendum, 2026-05-16): caller-quotes.
# The helper emits the RAW pathspec (`:(literal)` prefix + raw path bytes,
# including any apostrophes). Callers invoke as:
#   git ... -- "$(pp_safe_git_pathspec "$p")"
# The whole stdout is passed to git as ONE argv element by the shell's
# double-quoted command substitution; embedded apostrophes never break
# argv parsing because the shell never re-tokenizes the captured output.
# Git's pathspec syntax handles literal apostrophes inside `:(literal)`
# natively — no POSIX `'\''` escape needed.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

@test "pp_safe_git_pathspec: emits raw :(literal) magic for plain path" {
  . "$PP_ROOT/lib/grounding.sh"
  local out
  out=$(pp_safe_git_pathspec "src/foo.ts")
  [ "$out" = ":(literal)src/foo.ts" ]
}

@test "pp_safe_git_pathspec: strips trailing slash on a directory" {
  . "$PP_ROOT/lib/grounding.sh"
  local out
  out=$(pp_safe_git_pathspec "src/")
  [ "$out" = ":(literal)src" ]
}

@test "pp_safe_git_pathspec: preserves embedded single-quote (caller-quotes contract)" {
  . "$PP_ROOT/lib/grounding.sh"
  local out
  out=$(pp_safe_git_pathspec "weird'name.txt")
  # C1: caller-quotes contract. The helper returns RAW bytes; the caller
  # invokes via git ... -- "$(pp_safe_git_pathspec "$p")" so the apostrophe
  # is passed through to git as part of a single argv element. Git's
  # `:(literal)` pathspec treats it as a literal filename character.
  [ "$out" = ":(literal)weird'name.txt" ]
}

@test "pp_safe_git_pathspec: empty input returns 1 with no stdout" {
  . "$PP_ROOT/lib/grounding.sh"
  run pp_safe_git_pathspec ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "pp_safe_git_pathspec: leading dash rejected (no option-injection)" {
  . "$PP_ROOT/lib/grounding.sh"
  run pp_safe_git_pathspec "-rf"
  [ "$status" -eq 1 ]
  [ -z "$output" ]   # defensive: no accidental stdout emission on reject
}

@test "pp_safe_git_pathspec: single-slash input rejected after strip (empty)" {
  # "/" → after stripping trailing slash becomes "" → return 1.
  # Without the post-strip empty check, the helper would emit ":(literal)"
  # with no path body — which git would reject at runtime in a confusing way.
  . "$PP_ROOT/lib/grounding.sh"
  run pp_safe_git_pathspec "/"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "pp_safe_git_pathspec: round-trips through git log without globbing" {
  # In a temp repo, ensure the pathspec disables glob expansion.
  command -v git >/dev/null 2>&1 || skip "git not installed"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp -d) || skip "mktemp failed"
  # GPT review #9: ensure the temp dir is removed even when assertions
  # fail mid-test. bats teardown_per_test is per-file, not per-test, so
  # we use a local cleanup variable + trap analogue (since bats EXIT
  # trap is reserved by the runner).
  TEST_TMP="$_tmp"
  ( cd "$_tmp" && git init -q && touch 'star*.txt' real.txt \
    && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init ) \
    || { rm -rf "$_tmp"; skip "git init/commit failed in temp dir"; }
  local pathspec
  pathspec=$(pp_safe_git_pathspec "star*.txt")
  ( cd "$_tmp" && git log --pretty=%H -- "$pathspec" >/dev/null 2>&1 )
  local _rc="$?"
  rm -rf "$_tmp"   # always cleanup before assertion (bats short-circuits)
  unset TEST_TMP
  [ "$_rc" -eq 0 ]
}

# === v0.5.1.1 Stage A: pp_grounding_symbol_inventory ===
# Spec task 1: single FILE-READ-derived canonical symbol set, used by both
# the validator's VALID SYMBOLS block (Stage A) and the lens-side prompt
# SYMBOL block (Stage C). Stopword-filtered for parity with citations.sh.

@test "pp_grounding_symbol_inventory: extracts identifiers from a FILE READ block" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== GIT STATUS (uncommitted) ===
M src/foo.ts

=== FILE READ (planner picked: src/foo.ts) ===
export function calculateSum(a, b) { return a + b; }
const userAccount = makeAccount();
class WidgetController { render() {} }

=== SYMBOL REFERENCE COUNTS (grep across cwd) ===
calculateSum: 4 refs
EOF
  local out
  out=$(pp_grounding_symbol_inventory "$_tmp")
  rm -f "$_tmp"
  # All three identifiers appear, sorted, unique.
  printf '%s\n' "$out" | grep -qx 'calculateSum'
  printf '%s\n' "$out" | grep -qx 'userAccount'
  printf '%s\n' "$out" | grep -qx 'WidgetController'
}

@test "pp_grounding_symbol_inventory: drops stopwords (export, function, class, const, return)" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== FILE READ (planner picked: x.ts) ===
export function foo() { return 1; }
const bar = true;
class Baz {}
EOF
  local out
  out=$(pp_grounding_symbol_inventory "$_tmp")
  rm -f "$_tmp"
  # The stopwords MUST NOT appear in the output.
  ! printf '%s\n' "$out" | grep -qx 'export'
  ! printf '%s\n' "$out" | grep -qx 'function'
  ! printf '%s\n' "$out" | grep -qx 'class'
  ! printf '%s\n' "$out" | grep -qx 'const'
  ! printf '%s\n' "$out" | grep -qx 'return'
  ! printf '%s\n' "$out" | grep -qx 'true'
  # The actual identifiers DO appear.
  printf '%s\n' "$out" | grep -qx 'foo'
  printf '%s\n' "$out" | grep -qx 'bar'
  printf '%s\n' "$out" | grep -qx 'Baz'
}

@test "pp_grounding_symbol_inventory: output is sorted + unique" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== FILE READ (planner picked: dup.ts) ===
const zzz = 1;
const aaa = 2;
const zzz = 3;
const mmm = aaa + zzz;
EOF
  local out
  out=$(pp_grounding_symbol_inventory "$_tmp")
  rm -f "$_tmp"
  # Sorted ascending.
  [ "$(printf '%s\n' "$out" | head -1)" = "aaa" ]
  [ "$(printf '%s\n' "$out" | tail -1)" = "zzz" ]
  # Unique (zzz appears once).
  [ "$(printf '%s\n' "$out" | grep -c '^zzz$')" -eq 1 ]
}

@test "pp_grounding_symbol_inventory: empty FILE READ block returns empty stdout, rc=0" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== FILE READ (planner picked: empty.txt) ===
(no file read this round)

=== SYMBOL REFERENCE COUNTS (grep across cwd) ===
(no symbols extracted from file read)
EOF
  run pp_grounding_symbol_inventory "$_tmp"
  rm -f "$_tmp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pp_grounding_symbol_inventory: no FILE READ block at all returns empty, rc=0" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== GIT STATUS (uncommitted) ===
M src/foo.ts

=== RECENT COMMITS ===
abc123 fix: bar
EOF
  run pp_grounding_symbol_inventory "$_tmp"
  rm -f "$_tmp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pp_grounding_symbol_inventory: stops at next === header (does not bleed into GIT STATUS)" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== FILE READ (planner picked: a.ts) ===
const insideRead = 1;

=== GIT STATUS (uncommitted) ===
M outsideShouldNotMatch.ts
EOF
  local out
  out=$(pp_grounding_symbol_inventory "$_tmp")
  rm -f "$_tmp"
  printf '%s\n' "$out" | grep -qx 'insideRead'
  ! printf '%s\n' "$out" | grep -qx 'outsideShouldNotMatch'
}

@test "pp_grounding_symbol_inventory: missing facts file returns rc=1, empty stdout" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  run pp_grounding_symbol_inventory "/no/such/file/exists.txt"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "pp_grounding_symbol_inventory: short tokens (<3 chars) filtered" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== FILE READ (planner picked: short.ts) ===
let a = 1;
let bb = 2;
let ccc = 3;
const aReallyLongIdentifier = 4;
EOF
  local out
  out=$(pp_grounding_symbol_inventory "$_tmp")
  rm -f "$_tmp"
  ! printf '%s\n' "$out" | grep -qx 'a'
  ! printf '%s\n' "$out" | grep -qx 'bb'
  printf '%s\n' "$out" | grep -qx 'ccc'
  printf '%s\n' "$out" | grep -qx 'aReallyLongIdentifier'
}

# === v0.5.1.1 Stage A: pp_grounding_inventory_is_empty ===
# Spec task 6b: shared boolean used by both prompts/critique.md (Stage C)
# and bin/statusline.sh's validator block (Stage A) for EMPTY-ALLOWLIST
# parity.

@test "pp_grounding_inventory_is_empty: empty FILE READ block returns 0 (true: is empty)" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== FILE READ (planner picked: NONE) ===
(no file read this round)
EOF
  run pp_grounding_inventory_is_empty "$_tmp"
  rm -f "$_tmp"
  [ "$status" -eq 0 ]
}

@test "pp_grounding_inventory_is_empty: non-empty inventory returns 1 (false: not empty)" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== FILE READ (planner picked: real.ts) ===
const realIdentifier = 1;
EOF
  run pp_grounding_inventory_is_empty "$_tmp"
  rm -f "$_tmp"
  [ "$status" -eq 1 ]
}

@test "pp_grounding_inventory_is_empty: no FILE READ block at all returns 0 (true)" {
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  local _tmp
  _tmp=$(mktemp) || skip "mktemp failed"
  cat > "$_tmp" <<'EOF'
=== GIT STATUS (uncommitted) ===
M src/foo.ts
EOF
  run pp_grounding_inventory_is_empty "$_tmp"
  rm -f "$_tmp"
  [ "$status" -eq 0 ]
}

@test "pp_grounding_inventory_is_empty: missing file returns 0 (defensive: treat as empty)" {
  # If the facts file doesn't exist, there's no inventory to check
  # against - the EMPTY-ALLOWLIST EXCEPTION semantically applies (no
  # citation check enforceable). Returning 1 here would have the
  # critique flag every observation as DROP-no-allowlist, which is the
  # wrong default for a missing snapshot.
  . "$PP_ROOT/lib/citations.sh"
  . "$PP_ROOT/lib/grounding.sh"
  run pp_grounding_inventory_is_empty "/no/such/file.txt"
  [ "$status" -eq 0 ]
}
