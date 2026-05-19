#!/usr/bin/env bats

setup() {
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim-stats.sh"
}

@test "dim-stats: source guard prevents double-sourcing" {
  [ "${_PP_DIM_STATS_SOURCED:-0}" = "1" ]
  _before="$_PP_DIM_STATS_SOURCED"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim-stats.sh"
  [ "$_PP_DIM_STATS_SOURCED" = "$_before" ]
}
