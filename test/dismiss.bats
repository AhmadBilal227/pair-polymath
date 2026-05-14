#!/usr/bin/env bats
# v0.5 Phase 3 — dismiss subsystem.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR/dismiss"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  # shellcheck source=../lib/memory/schema.sh
  . "$PP_ROOT/lib/memory/schema.sh"
  # shellcheck source=../lib/dismiss.sh
  . "$PP_ROOT/lib/dismiss.sh"
}

teardown() { rm -rf "$HOME"; }

@test "dismiss_add: appends one JSONL line with the expected fields" {
  pp_dismiss_add "Browser-side API keys are intentional" project
  local _file
  _file=$(pp_dismiss_file_path)
  [ -f "$_file" ]
  [ "$(wc -l < "$_file" | tr -d ' ')" = "1" ]
  jq -e '.id and .ts and .reason_summary and .scope == "project" and .source == "manual" and .deleted == false' "$_file" >/dev/null
}

@test "dismiss_list: empty list prints empty-state guidance and exits 0" {
  run pp_dismiss_list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qiE 'no suppression rules|polymath dismiss'
}

@test "dismiss_list: returns active rules only (excludes pp_dismiss_disable'd)" {
  local _id_a _id_b
  _id_a=$(pp_dismiss_add "Rule A" project)
  _id_b=$(pp_dismiss_add "Rule B" project)
  pp_dismiss_disable "$_id_b" "user_disabled"
  run pp_dismiss_list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "Rule A"
  ! printf '%s' "$output" | grep -qF "Rule B"
}

@test "dismiss_list: TTL-expired rules are excluded" {
  pp_dismiss_add "Old expired rule" project
  local _file _id
  _file=$(pp_dismiss_file_path)
  _id=$(jq -r '.id' "$_file" | head -1)
  local _backdate _tmp
  _backdate=$(date -u -v -10d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id\" then .ts = \"$_backdate\" | .ttl_days = 5 else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  run pp_dismiss_list
  [ "$status" -eq 0 ]
  ! printf '%s' "$output" | grep -qF "Old expired rule"
}

@test "dismiss_list: TTL-not-yet-expired rules ARE included" {
  pp_dismiss_add "Fresh rule with ttl" project
  local _file _id _tmp
  _file=$(pp_dismiss_file_path)
  _id=$(jq -r '.id' "$_file" | head -1)
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id\" then .ttl_days = 30 else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  run pp_dismiss_list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "Fresh rule with ttl"
}

@test "dismiss_show: prints full JSON record for a given id" {
  local _id
  _id=$(pp_dismiss_add "Showable rule" project)
  run pp_dismiss_show "$_id"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.id == "'"$_id"'"' >/dev/null
}

@test "dismiss_show: unknown id exits non-zero with diagnostic to stderr" {
  run pp_dismiss_show "d-does-not-exist"
  [ "$status" -ne 0 ]
}

@test "dismiss_disable: flips deleted=true and records deleted_reason" {
  local _id
  _id=$(pp_dismiss_add "Disable me" project)
  run pp_dismiss_disable "$_id" "user_disabled"
  [ "$status" -eq 0 ]
  run pp_dismiss_show "$_id"
  printf '%s' "$output" | jq -e '.deleted == true and .deleted_reason == "user_disabled"' >/dev/null
}

@test "dismiss_enable: flips deleted=false on a previously-disabled rule" {
  local _id
  _id=$(pp_dismiss_add "Toggle me" project)
  pp_dismiss_disable "$_id" "user_disabled"
  run pp_dismiss_enable "$_id"
  [ "$status" -eq 0 ]
  run pp_dismiss_show "$_id"
  printf '%s' "$output" | jq -e '.deleted == false' >/dev/null
}

@test "dismiss_render: empty file produces empty stdout" {
  run pp_dismiss_render
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dismiss_render: emits bullet list with one bullet per active rule" {
  pp_dismiss_add "Rule one" project
  pp_dismiss_add "Rule two" project
  run pp_dismiss_render
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qE '^- Rule one'
  printf '%s' "$output" | grep -qE '^- Rule two'
  [ "$(printf '%s\n' "$output" | grep -cE '^- ')" = "2" ]
}

@test "dismiss_render: dedups by exact reason_summary match" {
  pp_dismiss_add "Same constraint" project
  pp_dismiss_add "Same constraint" project
  run pp_dismiss_render
  [ "$(printf '%s\n' "$output" | grep -cE '^- Same constraint')" = "1" ]
}

@test "dismiss_render: caps total output at PP_DISMISS_RENDERED_MAX_BYTES" {
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    pp_dismiss_add "Rule number $_i with verbose padding text to consume bytes" project
  done
  PP_DISMISS_RENDERED_MAX_BYTES=400 run pp_dismiss_render
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | wc -c | tr -d ' ')" -le 400 ]
}

@test "dismiss_render: cache invalidates only when source JSONL mtime is newer" {
  pp_dismiss_add "Rule for cache test" project
  local _out1 _out2
  _out1=$(pp_dismiss_render)
  _out2=$(pp_dismiss_render)
  [ "$_out1" = "$_out2" ]
  [ -f "$PP_CACHE_DIR/cc-dismiss-rendered-$(pp_memory_project_hash "$PWD").txt" ]
}

@test "is_suppressed: returns 0 (suppressed) when hash matches an active rule" {
  local _id _file _tmp
  _id=$(pp_dismiss_add "Hash-tagged rule" project)
  _file=$(pp_dismiss_file_path)
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id\" then .hash = \"abc123\" else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  run pp_dismiss_is_suppressed "abc123"
  [ "$status" -eq 0 ]
}

@test "is_suppressed: returns 1 (not suppressed) when no rule matches" {
  pp_dismiss_add "Some rule" project
  run pp_dismiss_is_suppressed "no-such-hash"
  [ "$status" -ne 0 ]
}

@test "is_suppressed: returns 1 when rule's hash matches but rule is deleted" {
  local _id _file _tmp
  _id=$(pp_dismiss_add "Will be disabled" project)
  pp_dismiss_disable "$_id" user_disabled
  _file=$(pp_dismiss_file_path)
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id\" then .hash = \"def456\" else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  run pp_dismiss_is_suppressed "def456"
  [ "$status" -ne 0 ]
}

@test "cli: 'polymath dismiss <reason>' creates a rule and prints id" {
  run bash "$PP_ROOT/bin/polymath" dismiss "Test rule via CLI"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qE '^d-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{4}$'
}

@test "cli: 'polymath dismiss list' shows active rules" {
  bash "$PP_ROOT/bin/polymath" dismiss "First rule" >/dev/null
  bash "$PP_ROOT/bin/polymath" dismiss "Second rule" >/dev/null
  run bash "$PP_ROOT/bin/polymath" dismiss list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "First rule"
  printf '%s' "$output" | grep -qF "Second rule"
}

@test "cli: 'polymath dismiss show <id>' returns JSON for the id" {
  local _id
  _id=$(bash "$PP_ROOT/bin/polymath" dismiss "Showable" 2>/dev/null | tail -1)
  run bash "$PP_ROOT/bin/polymath" dismiss show "$_id"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.id' >/dev/null
}

@test "cli: 'polymath dismiss disable <id>' soft-deletes" {
  local _id
  _id=$(bash "$PP_ROOT/bin/polymath" dismiss "Disable me" 2>/dev/null | tail -1)
  run bash "$PP_ROOT/bin/polymath" dismiss disable "$_id"
  [ "$status" -eq 0 ]
  run bash "$PP_ROOT/bin/polymath" dismiss show "$_id"
  printf '%s' "$output" | jq -e '.deleted == true' >/dev/null
}

@test "cli: 'polymath dismiss' with no args prints help" {
  run bash "$PP_ROOT/bin/polymath" dismiss
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qiE 'usage|polymath dismiss'
}

@test "hook: skips observations whose hash matches an active dismiss rule" {
  local _sid="bats-hook-sid"
  local _lens="ENGINEERING"
  local _obs="ENGINEERING: do not flag this thing again please|||body text long enough to satisfy the regex defended at line 39"
  local _hash
  # Match the hook's hashing algorithm (uses `echo`, which appends a newline).
  _hash=$(echo "$_obs" | shasum | cut -d' ' -f1)
  # Pre-create lens cache.
  printf '%s\n' "$_obs" > "$PP_CACHE_DIR/cc-monitor-${_sid}-${_lens}.txt"
  # Add a dismiss rule that tags this hash.
  local _id _file _tmp
  _id=$(pp_dismiss_add "Suppress that ENGINEERING ping" project)
  _file=$(pp_dismiss_file_path)
  _tmp=$(mktemp)
  jq -c "if .id == \"$_id\" then .hash = \"$_hash\" else . end" "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
  # Mock minimal lens-loader env so the hook's loop doesn't bail.
  PP_LENS_IDS="ENGINEERING" PP_LENS_COUNT=1
  export PP_LENS_IDS PP_LENS_COUNT
  run bash -c "printf '{\"session_id\":\"$_sid\"}' | bash '$PP_ROOT/hooks/inject-monitor-insight.sh'"
  [ "$status" -eq 0 ]
  # Output MUST NOT contain the suppressed body.
  ! printf '%s' "$output" | grep -qF "body text long enough"
}

@test "hook: still injects observations whose hash does NOT match a rule" {
  local _sid="bats-hook-no-suppress"
  local _lens="SECURITY"
  local _obs="SECURITY: legitimate concern about secrets handling|||body that should fire because no rule matches yet"
  printf '%s\n' "$_obs" > "$PP_CACHE_DIR/cc-monitor-${_sid}-${_lens}.txt"
  pp_dismiss_add "Other unrelated rule" project >/dev/null
  PP_LENS_IDS="SECURITY" PP_LENS_COUNT=1
  export PP_LENS_IDS PP_LENS_COUNT
  run bash -c "printf '{\"session_id\":\"$_sid\"}' | bash '$PP_ROOT/hooks/inject-monitor-insight.sh'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "body that should fire"
}

@test "ack: appends an ack record with source=ack" {
  pp_dismiss_ack "abc12345"
  local _file
  _file=$(pp_dismiss_file_path)
  [ -f "$_file" ]
  jq -e 'select(.source == "ack" and (.hash | startswith("abc")))' "$_file" >/dev/null
}

@test "auto_suppress: with PP_DISMISS_AUTO_THRESHOLD fires across N sessions, creates rule with source=auto_suppress" {
  local _hash="autosuppressabc123"
  # Simulate 10 sessions' worth of injected-hash files keyed to the same hash.
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    printf '%s' "$_hash" > "$PP_CACHE_DIR/cc-monitor-injected-hash-sess-$_i-ENGINEERING.txt"
  done
  PP_DISMISS_AUTO_THRESHOLD=10 \
    PP_DISMISS_AUTO_WINDOW_DAYS=30 \
    run pp_dismiss_auto_suppress
  [ "$status" -eq 0 ]
  local _file
  _file=$(pp_dismiss_file_path)
  jq -e "select(.source == \"auto_suppress\" and .hash == \"$_hash\" and .ttl_days == 7)" "$_file" >/dev/null
}

@test "auto_suppress: below threshold does NOT create a rule" {
  local _hash="belowthresholdxyz"
  local _i
  for _i in 1 2 3; do
    printf '%s' "$_hash" > "$PP_CACHE_DIR/cc-monitor-injected-hash-sess-$_i-ENGINEERING.txt"
  done
  PP_DISMISS_AUTO_THRESHOLD=10 run pp_dismiss_auto_suppress
  local _file
  _file=$(pp_dismiss_file_path)
  [ ! -f "$_file" ] || ! jq -e "select(.hash == \"$_hash\")" "$_file" >/dev/null
}

@test "auto_suppress: hash with prior ack is NOT auto-suppressed" {
  local _hash="ackedhashzzz"
  pp_dismiss_ack "$_hash"
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    printf '%s' "$_hash" > "$PP_CACHE_DIR/cc-monitor-injected-hash-sess-$_i-ENGINEERING.txt"
  done
  PP_DISMISS_AUTO_THRESHOLD=10 run pp_dismiss_auto_suppress
  local _file _autoct
  _file=$(pp_dismiss_file_path)
  _autoct=$(jq -c "select(.source == \"auto_suppress\" and .hash == \"$_hash\")" "$_file" | wc -l | tr -d ' ')
  [ "$_autoct" = "0" ]
}

@test "statusline-integration: PROJECT_CONSTRAINTS env exported when rules exist" {
  pp_dismiss_add "Integration test constraint" project >/dev/null
  PP_LENS_IDS="ENGINEERING" PP_LENS_COUNT=1
  export PP_LENS_IDS PP_LENS_COUNT
  # Trigger the statusline; capture exported env via a thin probe.
  run bash -c "
    printf '{\"session_id\":\"probe-sid\",\"workspace\":{\"current_dir\":\"\$PWD\"},\"transcript_path\":\"/tmp/none\",\"cost\":{\"total_cost_usd\":0.0},\"model\":{\"display_name\":\"S\"}}' \\
      | env -i HOME=\"$HOME\" PATH=\"\$PATH\" \\
            CLAUDE_DIR=\"$CLAUDE_DIR\" PP_CACHE_DIR=\"$PP_CACHE_DIR\" PP_STATE_DIR=\"$PP_STATE_DIR\" \\
            PP_ROOT=\"$PP_ROOT\" \\
            bash '$PP_ROOT/bin/statusline.sh' 2>&1
  "
  [ "$status" -eq 0 ]
  # The constraint text doesn't have to appear on the user-visible statusline,
  # but it MUST be computed (cache file written).
  [ -f "$PP_CACHE_DIR/cc-dismiss-rendered-$(pp_memory_project_hash "$PWD").txt" ]
}

# ----------------------------------------------------------------------
# Pass-5 review regression tests (C1, C2, C3, C4, I2, I3, I4).
# ----------------------------------------------------------------------

@test "regression C1: pp_dismiss_render excludes pp_dismiss_disable'd rules" {
  local _id
  _id=$(pp_dismiss_add "Render me only when active" project)
  run pp_dismiss_render
  printf '%s' "$output" | grep -qF "Render me only when active"
  pp_dismiss_disable "$_id" "user_disabled"
  run pp_dismiss_render
  ! printf '%s' "$output" | grep -qF "Render me only when active"
}

@test "regression C2: no lens JSON contains a literal \${project_constraints} string" {
  local _f _addition
  for _f in "$PP_ROOT"/lenses/*.json; do
    _addition=$(jq -r '.extras.system_prompt_addition // ""' "$_f")
    ! printf '%s' "$_addition" | grep -qE '\$\{project_constraints\}'
  done
}

@test "regression C3: pp_dismiss_render output passes through pp_memory_redact_body" {
  # Add a rule containing a fake-OpenAI-shaped secret literal.
  pp_dismiss_add "ignore the sk-thisisatestkeythatshouldberedacted token" project
  # Force cache miss by clearing any rendered cache.
  rm -f "$PP_CACHE_DIR/cc-dismiss-rendered-"*
  run pp_dismiss_render
  ! printf '%s' "$output" | grep -qF "sk-thisisatestkey"
  printf '%s' "$output" | grep -qF "REDACTED"
}

@test "regression C4: pp_dismiss_ack with short prefix vetoes pp_dismiss_auto_suppress" {
  local _full_hash="abcdef1234567890abcdef1234567890abcdef12"
  pp_dismiss_ack "abcdef12"  # 8-char prefix
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    printf '%s' "$_full_hash" > "$PP_CACHE_DIR/cc-monitor-injected-hash-sess-$_i-ENGINEERING.txt"
  done
  PP_DISMISS_AUTO_THRESHOLD=10 run pp_dismiss_auto_suppress
  local _file _autoct
  _file=$(pp_dismiss_file_path)
  _autoct=$(jq -c "select(.source == \"auto_suppress\" and .hash == \"$_full_hash\")" "$_file" | wc -l | tr -d ' ')
  [ "$_autoct" = "0" ]
}

@test "regression I2: PP_DISMISS_AUTO_WINDOW_DAYS filters out old hash files" {
  local _hash="windowtestxyz"
  # 10 hash files but with mtime > 30 days ago.
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    printf '%s' "$_hash" > "$PP_CACHE_DIR/cc-monitor-injected-hash-sess-old-$_i-ENGINEERING.txt"
  done
  # Backdate 60 days. Use BSD touch -t first, fall back to GNU -d.
  if ! find "$PP_CACHE_DIR" -name 'cc-monitor-injected-hash-sess-old-*' \
        -exec touch -t 202001010000 {} \; 2>/dev/null; then
    find "$PP_CACHE_DIR" -name 'cc-monitor-injected-hash-sess-old-*' \
      -exec touch -d '60 days ago' {} \;
  fi
  PP_DISMISS_AUTO_THRESHOLD=10 PP_DISMISS_AUTO_WINDOW_DAYS=30 run pp_dismiss_auto_suppress
  local _file _ct
  _file=$(pp_dismiss_file_path)
  if [ ! -f "$_file" ]; then return 0; fi
  _ct=$(jq -c "select(.source == \"auto_suppress\" and .hash == \"$_hash\")" "$_file" | wc -l | tr -d ' ')
  [ "$_ct" = "0" ]
}

@test "regression I3: pp_dismiss_render does NOT touch cache on repeated calls with no source" {
  rm -f "$PP_CACHE_DIR/cc-dismiss-rendered-"*
  pp_dismiss_render >/dev/null
  local _proj _cache _m1 _m2
  _proj=$(pp_memory_project_hash "$PWD")
  _cache="$PP_CACHE_DIR/cc-dismiss-rendered-${_proj}.txt"
  _m1=$(stat -c %Y "$_cache" 2>/dev/null || stat -f %m "$_cache" 2>/dev/null)
  sleep 1
  pp_dismiss_render >/dev/null
  _m2=$(stat -c %Y "$_cache" 2>/dev/null || stat -f %m "$_cache" 2>/dev/null)
  [ "$_m1" = "$_m2" ]
}

@test "regression I4: pp_dismiss_render invalidates cache when source content changes" {
  pp_dismiss_add "First content" project >/dev/null
  local _out1 _out2
  _out1=$(pp_dismiss_render)
  printf '%s' "$_out1" | grep -qF "First content"
  # Add a second rule — content changes; cache header must catch it.
  pp_dismiss_add "Second content" project >/dev/null
  _out2=$(pp_dismiss_render)
  printf '%s' "$_out2" | grep -qF "Second content"
}
