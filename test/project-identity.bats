#!/usr/bin/env bats
# Project identity isolation for OAR/history telemetry.

setup() {
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR"
  PROJECT="$HOME/project"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init >/dev/null 2>&1
  # shellcheck source=../lib/project-identity.sh
  . "$PP_ROOT/lib/project-identity.sh"
}

teardown() {
  rm -rf "$HOME"
}

@test "project identity: git repo gets a stable local project id" {
  id1=$(pp_project_id "$PROJECT")
  id2=$(pp_project_id "$PROJECT")
  [ "$id1" = "$id2" ]
  [[ "$id1" =~ ^[0-9a-f]{16}$ ]]
  [ -s "$PROJECT/.git/pair-polymath-project-id" ]
}

@test "project identity: non-git roots use state-dir mapping fallback" {
  nongit="$HOME/nongit"
  mkdir -p "$nongit"
  id1=$(pp_project_id "$nongit")
  id2=$(pp_project_id "$nongit")
  [ "$id1" = "$id2" ]
  root_hash=$(pp_project_hash "$(pp_project_real_root "$nongit")" | cut -c1-32)
  [ -s "$PP_STATE_DIR/identity/projects/${root_hash}.id" ]
}

@test "history defaults to current project and --all-projects is explicit" {
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  current_id=$(pp_project_id "$PROJECT")
  other_id="ffffffffffffffff"
  jq -nc --arg ts "$now_iso" --arg pid "$current_id" '
    {schema_version:2,session_id:"s-current",lens:"ENGINEERING",hash:"h1",
     inject_ts:$ts,labeled_at:$ts,outcome:"acted",confidence:"exact",
     identity:"id-current",project_id:$pid,project_root_sha8:"11111111"}' \
    > "$PP_CACHE_DIR/oar-labeled.jsonl"
  jq -nc --arg ts "$now_iso" --arg pid "$other_id" '
    {schema_version:2,session_id:"s-other",lens:"SECURITY",hash:"h2",
     inject_ts:$ts,labeled_at:$ts,outcome:"ignored",confidence:"no_signal_in_window",
     identity:"id-other",project_id:$pid,project_root_sha8:"22222222"}' \
    >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  jq -nc --arg ts "$now_iso" '
    {schema_version:2,session_id:"s-legacy",lens:"UX_DESIGN",hash:"h3",
     inject_ts:$ts,labeled_at:$ts,outcome:"ignored",confidence:"legacy",
     identity:"id-legacy"}' \
    >> "$PP_CACHE_DIR/oar-labeled.jsonl"

  run bash -c "cd '$PROJECT' && bash '$PP_ROOT/bin/polymath' history --json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.total == 1 and .by_outcome.acted == 1 and .all_projects == false' >/dev/null

  run bash -c "cd '$PROJECT' && bash '$PP_ROOT/bin/polymath' history --all-projects --json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.total == 3 and .all_projects == true' >/dev/null
}
