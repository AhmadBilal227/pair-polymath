#!/usr/bin/env bats
# v0.5.5 brand identity tests.
# Spec: docs/v0.5.5-brand-spec.md

setup() {
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$PP_TEST_HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  export PP_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
  mkdir -p "$PP_CACHE_DIR"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/brand.sh"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

# ----- The sigil -----

@test "brand AC1: sigil renders as ⚛ on UTF-8 locales" {
  LANG="en_US.UTF-8"
  export LANG
  result=$(_pp_brand_sigil)
  [ "$result" = '⚛' ]
}

@test "brand AC1b: sigil falls back to * on POSIX locale" {
  LANG="POSIX"
  unset LC_ALL
  export LANG
  result=$(_pp_brand_sigil)
  [ "$result" = '*' ]
}

@test "brand AC1c: PP_BRAND_SIGIL_ASCII=1 forces fallback" {
  LANG="en_US.UTF-8"
  PP_BRAND_SIGIL_ASCII=1
  export LANG PP_BRAND_SIGIL_ASCII
  result=$(_pp_brand_sigil)
  [ "$result" = '*' ]
}

@test "brand AC1d: sigil DEFAULTS to ⚛ when LANG unset (Claude Code statusline case)" {
  # Claude Code strips LANG when spawning the statusline subprocess.
  # Modern terminals render U+269B fine; default to ⚛.
  unset LANG LC_ALL LC_CTYPE
  result=$(_pp_brand_sigil)
  [ "$result" = '⚛' ]
}

@test "brand AC1e: LC_ALL=C wins over LANG=en_US.UTF-8 (POSIX precedence)" {
  LANG="en_US.UTF-8"
  LC_ALL="C"
  export LANG LC_ALL
  result=$(_pp_brand_sigil)
  [ "$result" = '*' ]
}

# ----- Lens-coded hues -----

@test "brand AC2: ENGINEERING hue is SOFT_AMBER (38;5;179)" {
  result=$(_pp_brand_lens_hue ENGINEERING)
  [[ "$result" == *"38;5;179m"* ]]
}

@test "brand AC2b: STRATEGIC_FOUNDER hue is SOFT_BLUE 110, NOT shared with UX_DESIGN" {
  # Post-review a11y fix: deuteranopia collision with SOFT_PURPLE (139).
  founder=$(_pp_brand_lens_hue STRATEGIC_FOUNDER)
  ux=$(_pp_brand_lens_hue UX_DESIGN)
  [[ "$founder" == *"38;5;110m"* ]]
  [[ "$ux" == *"38;5;139m"* ]]
  [ "$founder" != "$ux" ]
}

@test "brand AC2c: pp_brand_sigil_for_lens combines hue + sigil + reset" {
  LANG="en_US.UTF-8"
  export LANG
  result=$(pp_brand_sigil_for_lens SECURITY)
  [[ "$result" == *"38;5;167m"* ]]
  [[ "$result" == *"⚛"* ]]
  [[ "$result" == *"[0m"* ]]
}

# ----- Constellation (loading) -----

@test "brand AC3: loading frame is one of the 4 braille dots" {
  result=$(_pp_brand_loading_frame)
  case "$result" in
    '⠁'|'⠂'|'⠄'|'⡀') : ;;
    *) printf 'unexpected frame: %s\n' "$result" >&2; return 1 ;;
  esac
}

@test "brand AC3b: 4-frame rotation cycles by wall-clock seconds" {
  # Mock date by overriding the function in a subshell. The helper uses
  # `date +%s` so we can shadow it via a function.
  date() { printf '0\n'; }
  frame0=$(_pp_brand_loading_frame)
  date() { printf '1\n'; }
  frame1=$(_pp_brand_loading_frame)
  date() { printf '2\n'; }
  frame2=$(_pp_brand_loading_frame)
  date() { printf '3\n'; }
  frame3=$(_pp_brand_loading_frame)
  [ "$frame0" = '⠁' ]
  [ "$frame1" = '⠂' ]
  [ "$frame2" = '⠄' ]
  [ "$frame3" = '⡀' ]
}

# ----- Statusline integration -----

@test "brand AC4: paused statusline contains brand sigil prefix" {
  PP_EXTERNAL_LLM=0
  export PP_EXTERNAL_LLM
  LANG="en_US.UTF-8"
  export LANG
  run bash -c 'cat "$PP_ROOT/test/fixtures/stdin-sample.json" | bash "$PP_ROOT/bin/statusline.sh"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚛"* ]]
  [[ "$output" == *"paused — LLM cycle disabled"* ]]
}

# ----- ASCII banner -----

@test "brand AC5: pp_brand_banner emits 5 lines of filled-block art" {
  result=$(pp_brand_banner)
  line_count=$(printf '%s\n' "$result" | grep -c '█')
  [ "$line_count" -ge 5 ]
}

@test "brand AC6: constellation fires in statusline when cycle is in-flight" {
  # Wire test: simulate a fresh cycle lock (mkdir at PP_LOCK), then
  # invoke statusline and assert the constellation frame appears.
  # The session_id determines PP_LOCK path: /tmp/pp-fetch-${session_id}.lock
  local _sid
  _sid=$(jq -r '.session_id // "unknown"' < "$PP_ROOT/test/fixtures/stdin-sample.json")
  local _lock="/tmp/pp-fetch-${_sid}.lock"
  rm -rf "$_lock" 2>/dev/null
  mkdir "$_lock"
  trap 'rm -rf "$_lock" 2>/dev/null || true' EXIT
  unset PP_EXTERNAL_LLM
  run bash -c 'cat "$PP_ROOT/test/fixtures/stdin-sample.json" | bash "$PP_ROOT/bin/statusline.sh"'
  [ "$status" -eq 0 ]
  # Constellation glyph OR "thinking" copy should appear.
  [[ "$output" == *"thinking"* ]] || \
    [[ "$output" == *"⠁"* ]] || [[ "$output" == *"⠂"* ]] || \
    [[ "$output" == *"⠄"* ]] || [[ "$output" == *"⡀"* ]]
  rm -rf "$_lock"
}
