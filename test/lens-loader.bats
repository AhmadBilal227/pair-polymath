#!/usr/bin/env bats
# Lens loader: parses lenses/*.json, dedupes by id, sorts display_order,
# enforces hard cap, fails loud on zero loaded.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # Hermetic: isolated HOME so dev's real ~/.claude/pair-polymath/lenses
  # doesn't pollute the test results.
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  # shellcheck disable=SC1091
  . "${PP_ROOT}/lib/lens-loader.sh"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
  unset PP_LENS_MAX
}

@test "loader: loads all 7 built-in lenses" {
  pp_load_lenses
  [ "$PP_LENS_COUNT" -eq 7 ]
}

@test "loader: ids sorted by display_order" {
  pp_load_lenses
  [ "${PP_LENS_IDS[0]}" = "UX_DESIGN" ]
  [ "${PP_LENS_IDS[1]}" = "ENGINEERING" ]
  [ "${PP_LENS_IDS[6]}" = "COGNITIVE_FLOW" ]
}

@test "loader: each lens has non-empty hats + focus + color" {
  pp_load_lenses
  for i in $(seq 0 $((PP_LENS_COUNT - 1))); do
    [ -n "${PP_LENS_HATS[$i]}" ]
    [ -n "${PP_LENS_FOCUS[$i]}" ]
    [ -n "${PP_LENS_COLOR[$i]}" ]
  done
}

@test "loader: user lens override replaces built-in with matching id" {
  mkdir -p "$HOME/.claude/pair-polymath/lenses"
  cat > "$HOME/.claude/pair-polymath/lenses/01-ux-design.json" <<'JSON'
{
  "version": 1,
  "id": "UX_DESIGN",
  "display_order": 1,
  "hats": ["CUSTOM_HAT"],
  "focus": "user-override focus string",
  "color_hex": "#ff0000",
  "enabled": true,
  "extras": {}
}
JSON
  pp_load_lenses
  [ "$PP_LENS_COUNT" -eq 7 ]
  [ "${PP_LENS_IDS[0]}" = "UX_DESIGN" ]
  [ "${PP_LENS_FOCUS[0]}" = "user-override focus string" ]
  [ "${PP_LENS_HATS[0]}" = "CUSTOM_HAT" ]
}

@test "loader: respects PP_LENS_MAX cap (DoS guard against stuffed user dir)" {
  mkdir -p "$HOME/.claude/pair-polymath/lenses"
  for i in $(seq 1 25); do
    cat > "$HOME/.claude/pair-polymath/lenses/$(printf 'extra-%02d' "$i").json" <<JSON
{ "version": 1, "id": "EXTRA_$i", "display_order": $((100 + i)),
  "hats": ["X"], "focus": "filler $i", "color_hex": "#000000", "enabled": true }
JSON
  done
  export PP_LENS_MAX=10
  pp_load_lenses 2>/dev/null
  [ "$PP_LENS_COUNT" -eq 10 ]
}

@test "loader: zero lenses → return 1 + stderr warning" {
  # Point PP_ROOT at an empty dir, disable user dir, and confirm loud failure
  PP_ROOT_EMPTY="$(mktemp -d)"
  mkdir -p "$PP_ROOT_EMPTY/lenses"
  PP_ROOT="$PP_ROOT_EMPTY" run pp_load_lenses
  [ "$status" -eq 1 ]
  [[ "$output" == *"no lenses loaded"* ]]
  rm -rf "$PP_ROOT_EMPTY"
}

@test "Phase 2.1: each built-in lens JSON has non-empty extras.system_prompt_addition" {
  for f in "$PP_ROOT"/lenses/*.json; do
    val=$(jq -r '.extras.system_prompt_addition // ""' "$f")
    [ -n "$val" ] || { echo "FAIL: $f has empty extras.system_prompt_addition"; return 1; }
    # Sanity: at least 200 chars — guards against a future drive-by edit
    # that strips the persona back to a one-liner.
    [ "${#val}" -ge 200 ] || { echo "FAIL: $f system_prompt_addition too short (${#val} chars)"; return 1; }
  done
}

@test "Phase 2.1: each built-in lens JSON has at least 2 worked examples" {
  for f in "$PP_ROOT"/lenses/*.json; do
    n=$(jq -r '(.extras.examples // []) | length' "$f")
    [ "$n" -ge 2 ] || { echo "FAIL: $f has $n examples (need >=2)"; return 1; }
  done
}

@test "Phase 2.1: loader populates PP_LENS_SYSTEM_PROMPT_ADDITION + PP_LENS_EXAMPLES" {
  pp_load_lenses
  for i in $(seq 0 $((PP_LENS_COUNT - 1))); do
    [ -n "${PP_LENS_SYSTEM_PROMPT_ADDITION[$i]}" ] \
      || { echo "FAIL: lens $i (${PP_LENS_IDS[$i]}) has empty system_prompt_addition"; return 1; }
    [ -n "${PP_LENS_EXAMPLES[$i]}" ] \
      || { echo "FAIL: lens $i (${PP_LENS_IDS[$i]}) has empty examples"; return 1; }
    # Examples are joined with \n so a 2+-example lens has at least one newline
    case "${PP_LENS_EXAMPLES[$i]}" in
      *$'\n'*) ;;
      *) echo "FAIL: lens $i examples missing newline separator (need >=2 examples joined)"; return 1 ;;
    esac
  done
}

@test "Phase 2.1: lens file missing extras still loads (back-compat)" {
  # Old-format lens file (no extras at all) should still load — empty
  # system_prompt_addition + empty examples are acceptable for user lenses
  # written before Phase 2.1.
  mkdir -p "$HOME/.claude/pair-polymath/lenses"
  cat > "$HOME/.claude/pair-polymath/lenses/zz-legacy.json" <<'JSON'
{
  "version": 1,
  "id": "ZZ_LEGACY",
  "display_order": 200,
  "hats": ["LEGACY"],
  "focus": "old-format lens with no extras key",
  "color_hex": "#888888",
  "enabled": true
}
JSON
  pp_load_lenses
  # ZZ_LEGACY appears at the tail (display_order 200, > all built-ins)
  last=$((PP_LENS_COUNT - 1))
  [ "${PP_LENS_IDS[$last]}" = "ZZ_LEGACY" ]
  # Empty system_prompt_addition + examples — but loader must NOT have failed
  [ -z "${PP_LENS_SYSTEM_PROMPT_ADDITION[$last]}" ]
  [ -z "${PP_LENS_EXAMPLES[$last]}" ]
}

@test "loader: silent_reasons array parsed into PP_LENS_SILENT_REASONS (\\x1f-joined)" {
  pp_load_lenses
  # All 7 built-in lenses MUST declare silent_reasons (closed-enum invariant).
  for i in $(seq 0 $((PP_LENS_COUNT - 1))); do
    [ -n "${PP_LENS_SILENT_REASONS[$i]}" ] \
      || { echo "lens ${PP_LENS_IDS[$i]} missing silent_reasons"; return 1; }
  done
}

@test "loader: lens with no silent_reasons defaults to empty string (no crash)" {
  mkdir -p "$HOME/.claude/pair-polymath/lenses"
  cat > "$HOME/.claude/pair-polymath/lenses/01-ux-design.json" <<'JSON'
{
  "version": 1,
  "id": "UX_DESIGN",
  "display_order": 1,
  "hats": ["UX"],
  "focus": "f",
  "color_hex": "#000",
  "enabled": true,
  "extras": {}
}
JSON
  pp_load_lenses
  [ "${PP_LENS_IDS[0]}" = "UX_DESIGN" ]
  [ -z "${PP_LENS_SILENT_REASONS[0]}" ]
}

@test "loader: stable tiebreak when display_order ties" {
  mkdir -p "$HOME/.claude/pair-polymath/lenses"
  # Inject 2 user lenses both with display_order=100 — verify deterministic id-ascending order
  cat > "$HOME/.claude/pair-polymath/lenses/zz-banana.json" <<'JSON'
{ "version": 1, "id": "ZZ_BANANA", "display_order": 100, "hats": ["X"],
  "focus": "f", "color_hex": "#111111", "enabled": true }
JSON
  cat > "$HOME/.claude/pair-polymath/lenses/aa-apple.json" <<'JSON'
{ "version": 1, "id": "AA_APPLE", "display_order": 100, "hats": ["X"],
  "focus": "f", "color_hex": "#222222", "enabled": true }
JSON
  pp_load_lenses
  # Both new lenses appear at the tail (after the 7 built-ins, all display_order 1-7).
  # AA_APPLE sorts before ZZ_BANANA by id within the tied display_order=100.
  [ "${PP_LENS_IDS[7]}" = "AA_APPLE" ]
  [ "${PP_LENS_IDS[8]}" = "ZZ_BANANA" ]
}
