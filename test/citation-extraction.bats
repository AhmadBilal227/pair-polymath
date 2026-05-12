#!/usr/bin/env bats
# Phase 2.2 — deterministic citation extraction.
# Validates pp_extract_citations from lib/citations.sh:
#   - paths from GIT STATUS / FILES / CWD LISTING / TOOL CALLS
#   - symbols from FILE READ, with keyword stopwords filtered
#   - hard cap at 200 entries each
#   - empty input → empty output, no error
#   - deduplication

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # shellcheck disable=SC1091
  . "${PP_ROOT}/lib/citations.sh"
  # Hermetic: defensive defaults so failures show empty rather than $HOME leak.
  unset _pp_valid_paths _pp_valid_symbols
}

teardown() {
  unset grounded _pp_valid_paths _pp_valid_symbols
}

@test "citations: path extraction from GIT STATUS section" {
  grounded="=== GIT STATUS (uncommitted) ===
M handlers/users.ts
M lib/utils.ts
A new/file.js

=== USER RECENT MESSAGES ===
nothing here that should match
"
  pp_extract_citations
  [[ "$_pp_valid_paths" == *"handlers/users.ts"* ]]
  [[ "$_pp_valid_paths" == *"lib/utils.ts"* ]]
  [[ "$_pp_valid_paths" == *"new/file.js"* ]]
}

@test "citations: paths gathered from GIT RECENT FILES + CWD LISTING + RECENT TOOL CALLS" {
  grounded="=== GIT RECENT FILES ===
src/foo.py
README.md

=== CWD LISTING ===
docs/
package.json

=== RECENT TOOL CALLS (last 15) ===
Read: bin/statusline.sh
Edit: lib/citations.sh
"
  pp_extract_citations
  [[ "$_pp_valid_paths" == *"src/foo.py"* ]]
  [[ "$_pp_valid_paths" == *"README.md"* ]]
  [[ "$_pp_valid_paths" == *"docs/"* ]]
  [[ "$_pp_valid_paths" == *"package.json"* ]]
  [[ "$_pp_valid_paths" == *"bin/statusline.sh"* ]]
  [[ "$_pp_valid_paths" == *"lib/citations.sh"* ]]
}

@test "citations: symbol extraction from FILE READ (keeps identifiers, drops keywords)" {
  grounded="=== FILE READ (planner picked: src/sum.ts) ===
function calculateSum(a, b) { return a + b; }
class User extends Base {}
const userCount = 42;
"
  pp_extract_citations
  # Real identifiers retained
  [[ "$_pp_valid_symbols" == *"calculateSum"* ]]
  [[ "$_pp_valid_symbols" == *"User"* ]]
  [[ "$_pp_valid_symbols" == *"Base"* ]]
  [[ "$_pp_valid_symbols" == *"userCount"* ]]
  # Stopwords filtered. Use newline-aware grep so we never match a substring.
  ! printf '%s\n' "$_pp_valid_symbols" | grep -qx 'return'
  ! printf '%s\n' "$_pp_valid_symbols" | grep -qx 'function'
  ! printf '%s\n' "$_pp_valid_symbols" | grep -qx 'class'
  ! printf '%s\n' "$_pp_valid_symbols" | grep -qx 'const'
}

@test "citations: cap at 200 paths (500 distinct in → exactly 200 out)" {
  # Build a synthetic GIT STATUS body with 500 distinct paths.
  body=""
  for i in $(seq 1 500); do
    body="${body}M dir${i}/file.ts
"
  done
  grounded="=== GIT STATUS (uncommitted) ===
${body}
"
  pp_extract_citations
  count=$(printf '%s' "$_pp_valid_paths" | grep -c '.' || true)
  [ "$count" -eq 200 ]
}

@test "citations: cap at 200 symbols (500 distinct in → exactly 200 out)" {
  body=""
  for i in $(seq 1 500); do
    body="${body}identifierAlpha${i} "
  done
  grounded="=== FILE READ (planner picked: x.ts) ===
${body}
"
  pp_extract_citations
  count=$(printf '%s' "$_pp_valid_symbols" | grep -c '.' || true)
  [ "$count" -eq 200 ]
}

@test "citations: empty grounded → empty allowlists, no error" {
  grounded=""
  run pp_extract_citations
  [ "$status" -eq 0 ]
  # Re-source + invoke to observe globals from inside this test (run is a subshell).
  pp_extract_citations
  [ -z "$_pp_valid_paths" ]
  [ -z "$_pp_valid_symbols" ]
}

@test "citations: unset grounded → empty allowlists, no error" {
  unset grounded
  run pp_extract_citations
  [ "$status" -eq 0 ]
  pp_extract_citations
  [ -z "$_pp_valid_paths" ]
  [ -z "$_pp_valid_symbols" ]
}

@test "citations: deduplication — same path 3 times → once in output" {
  grounded="=== GIT STATUS (uncommitted) ===
M lib/utils.ts
M lib/utils.ts
M lib/utils.ts
"
  pp_extract_citations
  count=$(printf '%s\n' "$_pp_valid_paths" | grep -c '^lib/utils.ts$' || true)
  [ "$count" -eq 1 ]
}

@test "citations: only path-bearing sections are scanned (user messages ignored)" {
  # Paths in USER RECENT MESSAGES should NOT be in the allowlist — they're
  # user-typed, possibly hallucinated, and the whole point of the allowlist
  # is to root citations in deterministic-source sections.
  grounded="=== USER RECENT MESSAGES (PRIMARY CONTEXT) ===
please look at made-up/path.ts and fakefile.py

=== GIT STATUS (uncommitted) ===
M real/file.ts
"
  pp_extract_citations
  [[ "$_pp_valid_paths" == *"real/file.ts"* ]]
  # The user-mentioned paths should NOT be in the allowlist.
  ! printf '%s\n' "$_pp_valid_paths" | grep -qx 'made-up/path.ts'
  ! printf '%s\n' "$_pp_valid_paths" | grep -qx 'fakefile.py'
}
