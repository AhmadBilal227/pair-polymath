#!/usr/bin/env bats
# Lens loader: parses lenses/*.json, dedupes by id, sorts display_order.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # shellcheck disable=SC1091
  . "${PP_ROOT}/lib/lens-loader.sh"
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
