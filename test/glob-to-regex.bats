#!/usr/bin/env bats
# v0.5.1.1 Stage D — pp_lens_glob_to_regex unit tests.
#
# Pins the spec R3 conversion table. Golden file
# test/fixtures/v0.5.1.1/glob-to-regex-golden.txt is the contract; any
# tweak to the converter MUST update the golden in the same commit.
#
# Why golden-file-driven: the converter is the single load-bearing
# component that decides whether a lens fires on a path. Drift here
# silently bypasses every eligibility gate — golden file is the diff
# anchor that makes the drift impossible to land unreviewed.

setup() {
  PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export PP_ROOT
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/lens-loader.sh"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

# --- spec R3 conversion table (6 rules) ---

@test "glob_to_regex: rule 1 — **/ becomes (.*/)?" {
  result=$(pp_lens_glob_to_regex '**/foo.ts')
  [ "$result" = '^(.*/)?foo\.ts$' ]
}

@test "glob_to_regex: rule 2 — bare ** becomes .*" {
  result=$(pp_lens_glob_to_regex 'src/**')
  [ "$result" = '^src/.*$' ]
}

@test "glob_to_regex: rule 3 — * becomes [^/]* (does NOT cross directory)" {
  result=$(pp_lens_glob_to_regex 'src/*.ts')
  [ "$result" = '^src/[^/]*\.ts$' ]
}

@test "glob_to_regex: rule 4 — ? becomes [^/] (single non-slash char)" {
  result=$(pp_lens_glob_to_regex 'src/a?.ts')
  [ "$result" = '^src/a[^/]\.ts$' ]
}

@test "glob_to_regex: rule 5 — {a,b,c} becomes (a|b|c)" {
  result=$(pp_lens_glob_to_regex 'src/*.{ts,tsx}')
  [ "$result" = '^src/[^/]*\.(ts|tsx)$' ]
}

@test "glob_to_regex: rule 6 — regex metachars are escaped" {
  # Dot in the middle of a filename must NOT become a wildcard.
  result=$(pp_lens_glob_to_regex 'src/main.test.ts')
  [ "$result" = '^src/main\.test\.ts$' ]
}

# --- golden file round-trip (full 14-line fixture is the contract) ---

@test "glob_to_regex: golden file every non-comment line round-trips" {
  golden="$PP_ROOT/test/fixtures/v0.5.1.1/glob-to-regex-golden.txt"
  [ -f "$golden" ] || { echo "golden file missing: $golden"; return 1; }
  local fails=0 g r computed
  while IFS=$'\t' read -r g r; do
    case "$g" in
      ''|\#*) continue ;;
    esac
    [ -z "$r" ] && continue
    computed=$(pp_lens_glob_to_regex "$g")
    if [ "$computed" != "$r" ]; then
      printf '  FAIL: glob %q\n    expected: %s\n    got:      %s\n' \
        "$g" "$r" "$computed" >&2
      fails=$((fails + 1))
    fi
  done < "$golden"
  [ "$fails" -eq 0 ]
}

# --- match semantics through the regex (5 cases proving the regex WORKS) ---

@test "glob_to_regex: **/*.tsx matches src/components/Foo.tsx" {
  r=$(pp_lens_glob_to_regex '**/*.tsx')
  path='src/components/Foo.tsx'
  [[ "$path" =~ $r ]]
}

@test "glob_to_regex: **/*.tsx matches top-level Foo.tsx" {
  r=$(pp_lens_glob_to_regex '**/*.tsx')
  path='Foo.tsx'
  [[ "$path" =~ $r ]]
}

@test "glob_to_regex: src/*.ts does NOT match src/sub/foo.ts (single-* respects /)" {
  r=$(pp_lens_glob_to_regex 'src/*.ts')
  path='src/sub/foo.ts'
  if [[ "$path" =~ $r ]]; then
    echo "regex $r incorrectly matched $path"
    return 1
  fi
}

@test "glob_to_regex: **/*.{css,scss} matches styles/theme.scss" {
  r=$(pp_lens_glob_to_regex '**/*.{css,scss}')
  path='styles/theme.scss'
  [[ "$path" =~ $r ]]
}

@test "glob_to_regex: **/*.{css,scss} does NOT match styles/theme.less" {
  r=$(pp_lens_glob_to_regex '**/*.{css,scss}')
  path='styles/theme.less'
  if [[ "$path" =~ $r ]]; then
    echo "regex $r incorrectly matched $path"
    return 1
  fi
}

# --- edge cases ---

@test "glob_to_regex: paths with spaces are handled (regex is char-set based)" {
  r=$(pp_lens_glob_to_regex '**/copy/**')
  path='docs/copy/onboarding flow.md'
  [[ "$path" =~ $r ]]
}

@test "glob_to_regex: empty glob returns anchored-empty regex (defensive)" {
  result=$(pp_lens_glob_to_regex '')
  [ "$result" = '^$' ]
}
