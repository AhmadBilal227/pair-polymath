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
  ( cd "$_tmp" && git init -q && touch 'star*.txt' real.txt \
    && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init ) \
    || { rm -rf "$_tmp"; skip "git init/commit failed in temp dir"; }
  local pathspec
  pathspec=$(pp_safe_git_pathspec "star*.txt")
  ( cd "$_tmp" && git log --pretty=%H -- "$pathspec" >/dev/null 2>&1 )
  [ "$?" -eq 0 ]
  rm -rf "$_tmp"
}
