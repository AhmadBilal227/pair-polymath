#!/usr/bin/env bats
# Phase 2.2 — deterministic citation extraction.
# Validates pp_extract_citations from lib/citations.sh:
#   - paths from GIT STATUS / RECENT DIFF SCOPE / CWD TOP-LEVEL /
#     RECENT TOOL CALLS / OPEN PRS / RECENT CI RUNS (the sections
#     bin/statusline.sh actually emits)
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

@test "citations: paths gathered from CWD TOP-LEVEL + RECENT TOOL CALLS + RECENT DIFF SCOPE" {
  grounded="=== RECENT DIFF SCOPE ===
diff --git a/src/foo.py b/src/foo.py
+++ b/src/foo.py

=== CWD TOP-LEVEL ===
docs/
package.json
README.md

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

@test "citations: paths gathered from OPEN PRS + RECENT CI RUNS sections" {
  # These sections often carry paths in PR titles / CI run summaries.
  grounded="=== OPEN PRS (gh, cached 10min) ===
#42 fix(auth): tighten lib/auth.ts session check
#43 feat: add handlers/users.ts validation

=== RECENT CI RUNS (gh, cached 5min) ===
ci.yml run #1234 failed on test/integration.bats
"
  pp_extract_citations
  [[ "$_pp_valid_paths" == *"lib/auth.ts"* ]]
  [[ "$_pp_valid_paths" == *"handlers/users.ts"* ]]
  [[ "$_pp_valid_paths" == *"test/integration.bats"* ]]
}

@test "citations: paths from sections statusline.sh does NOT emit are NOT scanned" {
  # GIT RECENT FILES and CWD LISTING are NOT real grounded sections.
  # If the implementation accidentally scans them, this test catches it.
  grounded="=== GIT RECENT FILES ===
should-not-appear/phantom.ts

=== CWD LISTING ===
also-not-real/ghost.py

=== GIT STATUS (uncommitted) ===
M real/file.ts
"
  pp_extract_citations
  [[ "$_pp_valid_paths" == *"real/file.ts"* ]]
  ! printf '%s\n' "$_pp_valid_paths" | grep -qx 'should-not-appear/phantom.ts'
  ! printf '%s\n' "$_pp_valid_paths" | grep -qx 'also-not-real/ghost.py'
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

# === INTEGRATION TEST (R2 fix #4) ===
# Builds a synthetic grounded blob using the EXACT section headers that
# bin/statusline.sh emits in production (search bin/statusline.sh around
# lines 680-720 for the `=== ` markers). If the citations.sh section list
# ever drifts from statusline.sh again, this test breaks loudly.
#
# This is the test that WOULD have caught the R1 bug (citations.sh included
# GIT RECENT FILES and CWD LISTING — sections statusline.sh never emits).
@test "citations: INTEGRATION — extracts from real statusline.sh-emitted headers" {
  # Mirror the EXACT header strings from bin/statusline.sh. Do not paraphrase.
  grounded="=== USER RECENT MESSAGES (PRIMARY CONTEXT — focus your observation on this) ===
help me fix the user handler bug

=== GIT STATUS (uncommitted) ===
M handlers/users.ts
?? new-file.ts

=== RECENT COMMITS ===
abc1234 fix: minor cleanup
def5678 feat: add validation

=== RECENT DIFF SCOPE ===
diff --git a/lib/auth.ts b/lib/auth.ts
+++ b/lib/auth.ts

=== CWD TOP-LEVEL ===
package.json
src/
test/

=== RECENT TOOL CALLS (last 15) ===
TOOL(Read): bin/statusline.sh
TOOL(Edit): handlers/users.ts

=== OPEN PRS (gh, cached 10min) ===
#42 fix tests in test/integration.bats

=== RECENT CI RUNS (gh, cached 5min) ===
ci.yml passed on main

=== FILE READ (planner picked: src/sum.ts) ===
export function calculateSum(a, b) { return a + b; }
class User {}

=== SYMBOL REFERENCE COUNTS (grep across cwd) ===
calculateSum: 3

=== LAST TEST/LINT RUN (≤30min, from PostToolUse hook) ===
all green

=== PREVIOUS OBSERVATIONS (do not repeat these) ===
prior cycle noted X

=== TRANSCRIPT TAIL (last 5KB) ===
recent transcript content
"
  pp_extract_citations

  # PATHS must include items from each of the six path-bearing sections:
  [[ "$_pp_valid_paths" == *"handlers/users.ts"* ]]      # GIT STATUS
  [[ "$_pp_valid_paths" == *"lib/auth.ts"* ]]            # RECENT DIFF SCOPE
  [[ "$_pp_valid_paths" == *"package.json"* ]]           # CWD TOP-LEVEL
  [[ "$_pp_valid_paths" == *"bin/statusline.sh"* ]]      # RECENT TOOL CALLS
  [[ "$_pp_valid_paths" == *"test/integration.bats"* ]]  # OPEN PRS
  [[ "$_pp_valid_paths" == *"ci.yml"* ]]                 # RECENT CI RUNS

  # SYMBOLS must include identifiers from FILE READ, with stopwords filtered:
  [[ "$_pp_valid_symbols" == *"calculateSum"* ]]
  [[ "$_pp_valid_symbols" == *"User"* ]]
  # 'function' and 'class' are stopwords — should NOT appear.
  ! printf '%s\n' "$_pp_valid_symbols" | grep -qx 'function'
  ! printf '%s\n' "$_pp_valid_symbols" | grep -qx 'class'

  # NEGATIVE: paths/symbols ONLY appearing in non-path-bearing sections
  # (USER RECENT MESSAGES, PREVIOUS OBSERVATIONS, TRANSCRIPT TAIL) must NOT
  # leak into the allowlist. We don't put any path tokens there in this
  # fixture, but the symbol "transcript" appearing only in TRANSCRIPT TAIL
  # should not appear in valid_symbols (which comes only from FILE READ).
  ! printf '%s\n' "$_pp_valid_symbols" | grep -qx 'transcript'
  ! printf '%s\n' "$_pp_valid_symbols" | grep -qx 'cycle'
}
