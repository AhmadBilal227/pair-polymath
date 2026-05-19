#!/usr/bin/env bats

setup() {
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/state"
  PP_HOME="$CLAUDE_DIR/pair-polymath"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR PP_HOME
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR" "$PP_HOME"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/dim-stats.sh"
}

teardown() {
  if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    rm -rf "$HOME"
  fi
  return 0
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
  # Expected 20 (10%); allow ~3σ margin: 6-36. (σ ≈ 4.24 for n=200, p=0.1.)
  # The salt is random per-test, so wider bounds keep this test from flaking.
  [ "$in_holdout" -ge 6 ] 2>/dev/null
  [ "$in_holdout" -le 36 ] 2>/dev/null
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

@test "dim-stats: per-lens rollup groups by lens, counts acted, gates project_root_sha8" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  oar=$(mktemp)
  # 5 ENG rows (3 acted), 2 SEC rows (1 acted), 1 row from different project (excluded)
  cat > "$oar" <<'EOF'
{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s1","inject_ts":"2026-05-12T00:00:00Z","project_root_sha8":"abcd1234"}
{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s2","inject_ts":"2026-05-13T00:00:00Z","project_root_sha8":"abcd1234"}
{"schema_version":2,"lens":"ENG","outcome":"ignored","session_id":"s3","inject_ts":"2026-05-14T00:00:00Z","project_root_sha8":"abcd1234"}
{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s4","inject_ts":"2026-05-15T00:00:00Z","project_root_sha8":"abcd1234"}
{"schema_version":2,"lens":"ENG","outcome":"silent","session_id":"s5","inject_ts":"2026-05-16T00:00:00Z","project_root_sha8":"abcd1234"}
{"schema_version":2,"lens":"SEC","outcome":"acted","session_id":"s6","inject_ts":"2026-05-12T00:00:00Z","project_root_sha8":"abcd1234"}
{"schema_version":2,"lens":"SEC","outcome":"ignored","session_id":"s7","inject_ts":"2026-05-13T00:00:00Z","project_root_sha8":"abcd1234"}
{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s8","inject_ts":"2026-05-12T00:00:00Z","project_root_sha8":"zzz99999"}
EOF
  result=$(pp_dim_stats_per_lens_rollup "$oar" "abcd1234")
  # ENG: 5 rows total, 3 acted; verify totals across gated + holdout buckets
  # (strict .gated | length == 2 dropped — small n means a lens can land fully in holdout)
  echo "$result" | jq -e '
    ([.gated[], .holdout[] | select(.lens == "ENG")] | length) > 0
  ' >/dev/null
  echo "$result" | jq -e '
    ([.gated[], .holdout[] | select(.lens == "ENG") | .n] | add) == 5
  ' >/dev/null
  echo "$result" | jq -e '
    ([.gated[], .holdout[] | select(.lens == "ENG") | .s] | add) == 3
  ' >/dev/null
  # SEC: 2 rows total, 1 acted
  echo "$result" | jq -e '
    ([.gated[], .holdout[] | select(.lens == "SEC") | .n] | add) == 2
  ' >/dev/null
  echo "$result" | jq -e '
    ([.gated[], .holdout[] | select(.lens == "SEC") | .s] | add) == 1
  ' >/dev/null
  # Foreign project (zzz99999) must never appear in either bucket
  echo "$result" | jq -e '
    ([.gated[], .holdout[] | select(.lens == "ENG_FOREIGN" or (.lens | contains("zzz")))] | length) == 0
  ' >/dev/null
  rm -f "$oar"; rm -rf "$HOME"
}

@test "dim-stats: per-lens rollup splits gated vs holdout by slot 0" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  oar=$(mktemp)
  # 50 rows; exact split depends on salt so just assert holdout has some + total preserved
  for i in $(seq 1 50); do
    printf '{"schema_version":2,"lens":"ENG","outcome":"acted","session_id":"s%d","inject_ts":"2026-05-%02dT00:00:00Z","project_root_sha8":"abcd1234"}\n' \
      "$i" "$((10 + (i % 10)))" >> "$oar"
  done
  result=$(pp_dim_stats_per_lens_rollup "$oar" "abcd1234")
  gated_n=$(echo "$result" | jq -r '.gated[0].n')
  holdout_n=$(echo "$result" | jq -r '.holdout[0].n // 0')
  total=$((gated_n + holdout_n))
  [ "$total" = "50" ]
  # Holdout should be roughly 10% — allow 1-15 over 50
  [ "$holdout_n" -ge 1 ] 2>/dev/null
  [ "$holdout_n" -le 15 ] 2>/dev/null
  rm -f "$oar"; rm -rf "$HOME"
}

@test "dim-stats: per-lens rollup handles missing OAR file" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  result=$(pp_dim_stats_per_lens_rollup "/nonexistent" "abcd1234")
  echo "$result" | jq -e '.gated == [] and .holdout == []' >/dev/null
  rm -rf "$HOME"
}

# ---------------------------------------------------------------------------
# 5-reviewer critical-fix bundle regressions
# ---------------------------------------------------------------------------

@test "dim-stats: FIX#1 — setup creates hermetic HOME (no real pollution)" {
  # If setup() were not hermetic, $HOME would be the developer's real home.
  # We assert HOME is under /tmp or /var (mktemp's default), never the real
  # home directory.
  case "$HOME" in
    /tmp/*|/var/folders/*|/var/tmp/*|/private/tmp/*|/private/var/*) : ;;
    *) printf 'HOME (%s) is not under a temp dir — setup() is not hermetic\n' "$HOME" >&2; false ;;
  esac
  [ ! -e "$HOME/.claude/pair-polymath/dim-holdout-salt" ] || \
    [ "${HOME#/tmp/}" != "$HOME" ] || [ "${HOME#/var/}" != "$HOME" ] || \
    [ "${HOME#/private/}" != "$HOME" ]
}

@test "dim-stats: FIX#6 — sourcing the lib does not export LC_ALL to caller" {
  # The lib must not mutate LC_ALL globally. We unset before sourcing and
  # verify LC_ALL is still unset after.
  (
    unset LC_ALL
    # shellcheck disable=SC1091
    # Force re-source by clearing the guard
    _PP_DIM_STATS_SOURCED=0
    . "$PP_ROOT/lib/dim-stats.sh"
    [ -z "${LC_ALL:-}" ]
  )
}

@test "dim-stats: FIX#8 — sha256 fallback to cksum when no crypto hash available" {
  # Stub the hash commands by hiding them with a constrained PATH.
  # od, awk, cksum, tr live in /usr/bin or /bin; we need those.
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  hidden=$(mktemp -d)
  for cmd in shasum sha256sum openssl; do
    src=$(command -v "$cmd" 2>/dev/null) || continue
    # Create a placeholder that always errors out — masks the real one
    # without breaking PATH lookups for other tools.
    cat > "$hidden/$cmd" <<'EOF'
#!/bin/sh
exit 127
EOF
    chmod +x "$hidden/$cmd"
  done
  PATH="$hidden:$PATH" \
    bash -c '. '"$PP_ROOT"'/lib/dim-stats.sh
             # In this restricted env, holdout_slot should still emit 0..9.
             v=$(pp_dim_stats_holdout_slot "sess1" "ENG" "2026-05-19T00:00:00Z")
             [ "$v" -ge 0 ] && [ "$v" -le 9 ]'
  rm -rf "$hidden" "$HOME"
}

@test "dim-stats: FIX#11 — composite-gate handles non-numeric s/n/distinct_dates" {
  # Inject garbage: nulls, strings, missing fields. The function must NOT
  # crash and must coerce to qualifies=false (n_below_floor).
  input='[
    {"lens":"A","s":null,"n":"oops","distinct_dates":true},
    {"lens":"B"}
  ]'
  result=$(pp_dim_stats_composite_gate "$input" 0.05 0.05 3 250 5 2>/dev/null)
  echo "$result" | jq -e '.qualifies == false' >/dev/null
  echo "$result" | jq -e '.per_lens | length == 2' >/dev/null
}

@test "dim-stats: FIX#12 — ensure_salt refuses to write through a symlink" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  mkdir -p "$PP_HOME"
  # Pre-place a symlink at the salt path pointing to an attacker-controlled file.
  target=$(mktemp)
  ln -s "$target" "$PP_HOME/dim-holdout-salt"
  run _pp_dim_stats_ensure_salt
  [ "$status" -ne 0 ]
  # Symlink target must NOT have been written through.
  [ ! -s "$target" ]
  rm -f "$target"
}

@test "dim-stats: FIX#12 — ensure_salt creates parent dir with 0700 perms (umask 077)" {
  HOME="$(mktemp -d)"
  export HOME
  PP_HOME="$HOME/.claude/pair-polymath"
  export PP_HOME
  # Force loose umask in the caller; the helper must still create dir 0700.
  ( umask 022 && _pp_dim_stats_ensure_salt )
  perms=$(stat -f %p "$PP_HOME" 2>/dev/null | sed 's/^.*\([0-7][0-7][0-7]\)$/\1/' \
          || stat -c %a "$PP_HOME" 2>/dev/null)
  [ "$perms" = "700" ]
}
