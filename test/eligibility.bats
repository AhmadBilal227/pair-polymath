#!/usr/bin/env bats
# v0.5.1.1 Stage D — pp_lens_is_eligible unit tests.
#
# Spec: docs/v0.5.1.1-planner-grounding-fix-spec.md Change 3 / Task 9.
# Reads the FACTS SNAPSHOT (cc-monitor-facts-*.txt) and decides whether
# a given lens has any in-scope surface this cycle.

setup() {
  PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export PP_ROOT
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export PP_TEST_FACTS_DIR="$PP_TEST_HOME/facts"
  mkdir -p "$PP_TEST_FACTS_DIR"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/lens-loader.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/eligibility.sh"
  pp_load_lenses
}

teardown() {
  rm -rf "$PP_TEST_HOME"
  unset PP_TEST_FILE_READ PP_TEST_DIFF_PATHS PP_TEST_UNTRACKED_PATHS PP_TEST_STAGED_PATHS
}

# Helper: write a facts file with the v0.5.1.1 schema headers.
_write_facts() {
  local outfile="$1"
  cat > "$outfile" <<EOF
# facts_schema: 2
=== USER RECENT MESSAGES (PRIMARY CONTEXT — focus your observation on this) ===
(omitted for test)

=== FILE READ (planner picked: ${PP_TEST_FILE_READ:-NONE}) ===
(omitted)

# git_diff_paths
${PP_TEST_DIFF_PATHS:-}
# /git_diff_paths

# git_untracked_paths
${PP_TEST_UNTRACKED_PATHS:-}
# /git_untracked_paths

# git_staged_paths
${PP_TEST_STAGED_PATHS:-}
# /git_staged_paths
EOF
}

# --- kind: always trivially returns 0 ---

@test "eligibility: STRATEGIC_FOUNDER (kind=always) returns 0 on empty snapshot" {
  PP_TEST_FILE_READ="NONE"
  _write_facts "$PP_TEST_FACTS_DIR/empty.txt"
  run pp_lens_is_eligible "STRATEGIC_FOUNDER" "$PP_TEST_FACTS_DIR/empty.txt"
  [ "$status" -eq 0 ]
}

@test "eligibility: COGNITIVE_FLOW (kind=always) returns 0 even with weird path set" {
  PP_TEST_FILE_READ="bin/whatever"
  PP_TEST_DIFF_PATHS="bin/whatever"
  _write_facts "$PP_TEST_FACTS_DIR/weird.txt"
  run pp_lens_is_eligible "COGNITIVE_FLOW" "$PP_TEST_FACTS_DIR/weird.txt"
  [ "$status" -eq 0 ]
}

# --- kind: path_glob OR-match across snapshot path set ---

@test "eligibility: UX_DESIGN matches when FILE READ is a .tsx file" {
  PP_TEST_FILE_READ="src/components/Foo.tsx"
  _write_facts "$PP_TEST_FACTS_DIR/tsx.txt"
  run pp_lens_is_eligible "UX_DESIGN" "$PP_TEST_FACTS_DIR/tsx.txt"
  [ "$status" -eq 0 ]
}

@test "eligibility: UX_DESIGN matches via git_diff_paths even when FILE READ is non-UI" {
  PP_TEST_FILE_READ="bin/script.sh"
  PP_TEST_DIFF_PATHS="src/screens/Login.tsx"
  _write_facts "$PP_TEST_FACTS_DIR/diff.txt"
  run pp_lens_is_eligible "UX_DESIGN" "$PP_TEST_FACTS_DIR/diff.txt"
  [ "$status" -eq 0 ]
}

@test "eligibility: UX_DESIGN does NOT match on pure-shell snapshot" {
  PP_TEST_FILE_READ="bin/statusline.sh"
  PP_TEST_DIFF_PATHS="bin/statusline.sh"$'\n'"lib/router.sh"
  PP_TEST_STAGED_PATHS="lib/router.sh"
  _write_facts "$PP_TEST_FACTS_DIR/sh.txt"
  run pp_lens_is_eligible "UX_DESIGN" "$PP_TEST_FACTS_DIR/sh.txt"
  [ "$status" -eq 1 ]
}

@test "eligibility: ENGINEERING matches on pure-shell snapshot (.sh ∈ code globs)" {
  PP_TEST_FILE_READ="bin/statusline.sh"
  PP_TEST_DIFF_PATHS="bin/statusline.sh"
  _write_facts "$PP_TEST_FACTS_DIR/sh.txt"
  run pp_lens_is_eligible "ENGINEERING" "$PP_TEST_FACTS_DIR/sh.txt"
  [ "$status" -eq 0 ]
}

@test "eligibility: SECURITY matches on pure-shell snapshot (.sh ∈ code globs)" {
  PP_TEST_FILE_READ="lib/grounding.sh"
  PP_TEST_DIFF_PATHS="lib/grounding.sh"
  _write_facts "$PP_TEST_FACTS_DIR/sh.txt"
  run pp_lens_is_eligible "SECURITY" "$PP_TEST_FACTS_DIR/sh.txt"
  [ "$status" -eq 0 ]
}

# --- ignored dirs filter ---

@test "eligibility: ignored dirs (node_modules/, .git/, dist/, etc.) stripped before regex" {
  # If we DID NOT strip node_modules/, ENGINEERING's **/*.ts glob would
  # match node_modules/foo/index.ts and the lens would always fire.
  PP_TEST_FILE_READ="NONE"
  PP_TEST_DIFF_PATHS="node_modules/foo/index.ts"$'\n'"dist/bundle.js"$'\n'".git/HEAD"
  _write_facts "$PP_TEST_FACTS_DIR/ignored.txt"
  run pp_lens_is_eligible "ENGINEERING" "$PP_TEST_FACTS_DIR/ignored.txt"
  [ "$status" -eq 1 ]
}

@test "eligibility: a real src/ path among node_modules entries STILL matches (filter is per-path)" {
  PP_TEST_FILE_READ="NONE"
  PP_TEST_DIFF_PATHS="node_modules/foo/index.ts"$'\n'"src/real.ts"
  _write_facts "$PP_TEST_FACTS_DIR/mixed.txt"
  run pp_lens_is_eligible "ENGINEERING" "$PP_TEST_FACTS_DIR/mixed.txt"
  [ "$status" -eq 0 ]
}

# --- gitless fallback ---

@test "eligibility: missing git_*_paths blocks (gitless cwd) does NOT crash" {
  # Write a facts file WITHOUT the git_* blocks (legacy v1 schema).
  cat > "$PP_TEST_FACTS_DIR/gitless.txt" <<'EOF'
# facts_schema: 1
=== FILE READ (planner picked: src/components/Foo.tsx) ===
(omitted)
EOF
  run pp_lens_is_eligible "UX_DESIGN" "$PP_TEST_FACTS_DIR/gitless.txt"
  [ "$status" -eq 0 ]
  # And the same with a lens that should NOT match:
  cat > "$PP_TEST_FACTS_DIR/gitless2.txt" <<'EOF'
# facts_schema: 1
=== FILE READ (planner picked: bin/script.sh) ===
(omitted)
EOF
  run pp_lens_is_eligible "UX_DESIGN" "$PP_TEST_FACTS_DIR/gitless2.txt"
  [ "$status" -eq 1 ]
}

# --- multi-glob OR within one lens ---

@test "eligibility: UX_DESIGN matches via second any_of branch (.scss)" {
  # UX_DESIGN's eligibility has any_of: [tsx/jsx/components/screens, css/scss/styles, svg/icons/assets].
  # A pure-CSS change must hit the second branch.
  PP_TEST_FILE_READ="NONE"
  PP_TEST_DIFF_PATHS="src/styles/theme.scss"
  _write_facts "$PP_TEST_FACTS_DIR/css.txt"
  run pp_lens_is_eligible "UX_DESIGN" "$PP_TEST_FACTS_DIR/css.txt"
  [ "$status" -eq 0 ]
}

@test "eligibility: PRODUCT_BIZ matches on a copy/ markdown edit" {
  PP_TEST_FILE_READ="NONE"
  PP_TEST_DIFF_PATHS="docs/copy/onboarding.mdx"
  _write_facts "$PP_TEST_FACTS_DIR/copy.txt"
  run pp_lens_is_eligible "PRODUCT_BIZ" "$PP_TEST_FACTS_DIR/copy.txt"
  [ "$status" -eq 0 ]
}

# --- edge cases ---

@test "eligibility: unknown lens id returns 1 (defensive)" {
  PP_TEST_FILE_READ="src/components/Foo.tsx"
  _write_facts "$PP_TEST_FACTS_DIR/unknown.txt"
  run pp_lens_is_eligible "NONEXISTENT_LENS" "$PP_TEST_FACTS_DIR/unknown.txt"
  [ "$status" -eq 1 ]
}

@test "eligibility: missing facts file does not crash (returns 1 for path_glob lens)" {
  run pp_lens_is_eligible "UX_DESIGN" "$PP_TEST_FACTS_DIR/missing-file.txt"
  [ "$status" -eq 1 ]
}

@test "eligibility: missing facts file still returns 0 for kind=always lens" {
  run pp_lens_is_eligible "STRATEGIC_FOUNDER" "$PP_TEST_FACTS_DIR/missing-file.txt"
  [ "$status" -eq 0 ]
}

@test "eligibility: git_staged_paths alone (FILE READ NONE, no diff/untracked) suffices" {
  PP_TEST_FILE_READ="NONE"
  PP_TEST_STAGED_PATHS="src/components/Header.tsx"
  _write_facts "$PP_TEST_FACTS_DIR/staged.txt"
  run pp_lens_is_eligible "UX_DESIGN" "$PP_TEST_FACTS_DIR/staged.txt"
  [ "$status" -eq 0 ]
}

@test "eligibility: git_untracked_paths alone suffices" {
  PP_TEST_FILE_READ="NONE"
  PP_TEST_UNTRACKED_PATHS="src/screens/NewScreen.tsx"
  _write_facts "$PP_TEST_FACTS_DIR/untracked.txt"
  run pp_lens_is_eligible "UX_DESIGN" "$PP_TEST_FACTS_DIR/untracked.txt"
  [ "$status" -eq 0 ]
}

# --- binary file filter (NUL-byte sniff) ---

@test "eligibility: real binary file on disk is filtered before regex pass" {
  # Construct a "src/blob.ts" with NUL bytes in the first 512B; should be
  # filtered out by the binary-file heuristic even though .ts matches
  # ENGINEERING's first regex.
  mkdir -p "$PP_TEST_HOME/work/src"
  cd "$PP_TEST_HOME/work" || return 1
  printf 'hello\x00world\x00\x00\x00binary' > "src/blob.ts"
  PP_TEST_FILE_READ="src/blob.ts"
  _write_facts "$PP_TEST_FACTS_DIR/binary.txt"
  run pp_lens_is_eligible "ENGINEERING" "$PP_TEST_FACTS_DIR/binary.txt"
  [ "$status" -eq 1 ]
}

@test "eligibility: real text file with same name is NOT filtered" {
  # Sanity-check the inverse: same path, but text contents, must pass.
  mkdir -p "$PP_TEST_HOME/work/src"
  cd "$PP_TEST_HOME/work" || return 1
  printf 'export const foo = 1\n' > "src/blob.ts"
  PP_TEST_FILE_READ="src/blob.ts"
  _write_facts "$PP_TEST_FACTS_DIR/text.txt"
  run pp_lens_is_eligible "ENGINEERING" "$PP_TEST_FACTS_DIR/text.txt"
  [ "$status" -eq 0 ]
}
