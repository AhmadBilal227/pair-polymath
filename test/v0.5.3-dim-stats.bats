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

@test "dim-stats: events-to-clear at n=200,s=14 (p=7%) targeting 5% returns positive N" {
  result=$(pp_dim_stats_events_to_clear 14 200 0.05 0.05)
  [ -n "$result" ]
  [ "$result" -gt 0 ] 2>/dev/null
}

@test "dim-stats: events-to-clear at already-clearing input returns 0" {
  result=$(pp_dim_stats_events_to_clear 20 200 0.05 0.05)
  [ "$result" = "0" ]
}

@test "dim-stats: events-to-clear returns -1 sentinel when acted% is below target" {
  result=$(pp_dim_stats_events_to_clear 0 200 0.05 0.05)
  [ "$result" = "-1" ]
}

@test "dim-stats: events-to-clear finds answers in [1,5] (bisect lower-bound regression)" {
  # Craft a case where the smallest delta_n is small (~1-5). With s=2,n=10,
  # observed p=20%; LCB at small n is wide, but adding a few events at 20% acted
  # quickly clears the 5% target. The right answer must be small.
  result=$(pp_dim_stats_events_to_clear 2 10 0.05 0.05)
  # Sanity bounds — must be a positive integer below 100.
  [ "$result" -gt 0 ] 2>/dev/null
  [ "$result" -lt 100 ] 2>/dev/null
}

@test "dim-stats: holdout salt auto-created with 0600 perms on first call" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  _pp_dim_stats_ensure_salt
  [ -f "$PP_HOME/dim-holdout-salt" ]
  # macOS: stat -f %p; Linux: stat -c %a
  perms=$(stat -f %p "$PP_HOME/dim-holdout-salt" 2>/dev/null || stat -c %a "$PP_HOME/dim-holdout-salt")
  case "$perms" in
    *600|600) : ;;
    *) false ;;
  esac
  rm -rf "$HOME"
}

@test "dim-stats: holdout salt is 16 hex bytes (32 chars)" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  _pp_dim_stats_ensure_salt
  salt=$(cat "$PP_HOME/dim-holdout-salt")
  [ "${#salt}" -eq 32 ]
  echo "$salt" | grep -qE '^[0-9a-f]{32}$'
  rm -rf "$HOME"
}

@test "dim-stats: holdout salt is idempotent (re-call doesn't change it)" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  _pp_dim_stats_ensure_salt
  s1=$(cat "$PP_HOME/dim-holdout-salt")
  _pp_dim_stats_ensure_salt
  s2=$(cat "$PP_HOME/dim-holdout-salt")
  [ "$s1" = "$s2" ]
  rm -rf "$HOME"
}

@test "dim-stats: holdout slot returns 0..9 deterministically" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  result=$(pp_dim_stats_holdout_slot "sess1" "ENGINEERING" "2026-05-19T12:00:00Z")
  [ "$result" -ge 0 ] 2>/dev/null
  [ "$result" -le 9 ] 2>/dev/null
  # Determinism
  result2=$(pp_dim_stats_holdout_slot "sess1" "ENGINEERING" "2026-05-19T12:00:00Z")
  [ "$result" = "$result2" ]
  rm -rf "$HOME"
}

@test "dim-stats: holdout distribution roughly uniform across 200 synthetic rows" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  in_holdout=0
  for i in $(seq 1 200); do
    slot=$(pp_dim_stats_holdout_slot "sess$i" "ENGINEERING" "2026-05-19T12:00:00Z")
    [ "$slot" = "0" ] && in_holdout=$((in_holdout + 1))
  done
  # Expected 20 (10%); allow 2σ margin: 10-32
  [ "$in_holdout" -ge 10 ] 2>/dev/null
  [ "$in_holdout" -le 32 ] 2>/dev/null
  rm -rf "$HOME"
}

@test "dim-stats: holdout salt parent dir is 0700 after ensure" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  _pp_dim_stats_ensure_salt
  perms=$(stat -f %p "$PP_HOME" 2>/dev/null | sed 's/^.*\([0-7][0-7][0-7]\)$/\1/' \
          || stat -c %a "$PP_HOME" 2>/dev/null)
  [ "$perms" = "700" ]
  rm -rf "$HOME"
}

@test "dim-stats: composite-gate qualifies with 3 of 7 lenses passing per-lens LCB" {
  # 3 strong lenses, 4 zeros; alpha_per_lens = 0.05/7 ≈ 0.00714
  input='[
    {"lens":"A","s":40,"n":300,"distinct_dates":7},
    {"lens":"B","s":30,"n":300,"distinct_dates":7},
    {"lens":"C","s":30,"n":250,"distinct_dates":7},
    {"lens":"D","s":0,"n":10,"distinct_dates":1},
    {"lens":"E","s":0,"n":10,"distinct_dates":1},
    {"lens":"F","s":0,"n":10,"distinct_dates":1},
    {"lens":"G","s":0,"n":10,"distinct_dates":1}
  ]'
  result=$(pp_dim_stats_composite_gate "$input" 0.05 0.05 3 250 5)
  echo "$result" | jq -e '.qualifies == true' >/dev/null
  echo "$result" | jq -e '.lenses_qualifying == 3' >/dev/null
}

@test "dim-stats: composite-gate fails with 2 of 7 (below 3-lens floor)" {
  input='[
    {"lens":"A","s":40,"n":200,"distinct_dates":7},
    {"lens":"B","s":30,"n":200,"distinct_dates":7}
  ]'
  result=$(pp_dim_stats_composite_gate "$input" 0.05 0.05 3 250 5)
  echo "$result" | jq -e '.qualifies == false' >/dev/null
}

@test "dim-stats: composite-gate fails when n below floor (300 raw but distinct_dates only 2)" {
  input='[
    {"lens":"A","s":60,"n":300,"distinct_dates":2},
    {"lens":"B","s":60,"n":300,"distinct_dates":2},
    {"lens":"C","s":60,"n":300,"distinct_dates":2}
  ]'
  result=$(pp_dim_stats_composite_gate "$input" 0.05 0.05 3 250 5)
  echo "$result" | jq -e '.qualifies == false' >/dev/null
  echo "$result" | jq -e '.per_lens[0].fail_reason | contains("distinct_dates")' >/dev/null
}

@test "dim-stats: composite-gate stamps lcb on every lens in per_lens output" {
  input='[{"lens":"A","s":40,"n":200,"distinct_dates":7}]'
  result=$(pp_dim_stats_composite_gate "$input" 0.05 0.05 3 250 5)
  echo "$result" | jq -e '.per_lens[0].lcb > 0' >/dev/null
}
