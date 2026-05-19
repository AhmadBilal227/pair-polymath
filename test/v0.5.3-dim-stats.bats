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

@test "dim-stats: anytime LCB at n=200, s=20 (true p=10%) clears 5%" {
  result=$(pp_dim_stats_lcb_anytime 20 200 0.05)
  awk -v r="$result" 'BEGIN { exit (r >= 0.05) ? 0 : 1 }'
}

@test "dim-stats: anytime LCB at n=200, s=14 (true p=7%) does NOT clear 5%" {
  result=$(pp_dim_stats_lcb_anytime 14 200 0.05)
  awk -v r="$result" 'BEGIN { exit (r < 0.05) ? 0 : 1 }'
}

@test "dim-stats: anytime LCB at n=0 returns 0" {
  result=$(pp_dim_stats_lcb_anytime 0 0 0.05)
  awk -v r="$result" 'BEGIN { exit (r == 0) ? 0 : 1 }'
}

@test "dim-stats: anytime LCB at s=n=1 returns >0" {
  result=$(pp_dim_stats_lcb_anytime 1 1 0.05)
  awk -v r="$result" 'BEGIN { exit (r > 0) ? 0 : 1 }'
}

@test "dim-stats: anytime LCB monotone increasing in s for fixed n" {
  a=$(pp_dim_stats_lcb_anytime 10 200 0.05)
  b=$(pp_dim_stats_lcb_anytime 20 200 0.05)
  awk -v a="$a" -v b="$b" 'BEGIN { exit (b > a) ? 0 : 1 }'
}

@test "dim-stats: anytime LCB monotone decreasing in n for fixed p=s/n" {
  a=$(pp_dim_stats_lcb_anytime 10 100 0.05)
  b=$(pp_dim_stats_lcb_anytime 20 200 0.05)
  c=$(pp_dim_stats_lcb_anytime 100 1000 0.05)
  awk -v a="$a" -v b="$b" -v c="$c" 'BEGIN { exit (a < b && b < c) ? 0 : 1 }'
}

@test "dim-stats: anytime LCB with alpha=0 returns 0 (refuse, not inf)" {
  result=$(pp_dim_stats_lcb_anytime 20 200 0)
  awk -v r="$result" 'BEGIN { exit (r == 0) ? 0 : 1 }'
}

@test "dim-stats: anytime LCB with alpha=2 returns 0 (refuse, not over-confident)" {
  result=$(pp_dim_stats_lcb_anytime 20 200 2)
  awk -v r="$result" 'BEGIN { exit (r == 0) ? 0 : 1 }'
}

@test "dim-stats: anytime LCB with alpha=-0.1 returns 0 (refuse negative)" {
  result=$(pp_dim_stats_lcb_anytime 20 200 -0.1)
  awk -v r="$result" 'BEGIN { exit (r == 0) ? 0 : 1 }'
}

@test "dim-stats: anytime LCB locale-stable (LC_ALL=fr_FR.UTF-8)" {
  result=$(LC_ALL=fr_FR.UTF-8 pp_dim_stats_lcb_anytime 20 200 0.05)
  ! echo "$result" | grep -q ','
  awk -v r="$result" 'BEGIN { exit (r >= 0.05) ? 0 : 1 }'
}
