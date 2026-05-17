#!/usr/bin/env bats
# v0.5.1 — SessionEnd hook scaffold (OAR prerequisite).

setup() {
  HOME="$(mktemp -d)"; export HOME
  PP_CACHE_DIR="$HOME/.claude/cache"
  PP_STATE_DIR="$HOME/.claude/pair-polymath"
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR"
  export PP_CACHE_DIR PP_STATE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}
teardown() { rm -rf "$HOME"; }

@test "session-end: no-op when PP_OAR_ENABLE=0 (default)" {
  unset PP_OAR_ENABLE
  run bash -c "printf '{\"session_id\":\"s1\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  [ ! -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
}

@test "session-end: writes oar-pending records when PP_OAR_ENABLE=1" {
  # Pre-create some injection-hash files for the session
  printf 'hash-abc' > "$PP_CACHE_DIR/cc-monitor-injected-hash-s1-ENGINEERING.txt"
  printf 'hash-def' > "$PP_CACHE_DIR/cc-monitor-injected-hash-s1-SECURITY.txt"
  export PP_OAR_ENABLE=1
  run bash -c "printf '{\"session_id\":\"s1\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  [ -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
  [ "$(wc -l < "$PP_CACHE_DIR/oar-pending.jsonl" | tr -d ' ')" -ge 2 ]
}

@test "session-end: reads PP_OAR_ENABLE from persistent user.env" {
  mkdir -p "$PP_STATE_DIR/config"
  printf 'PP_OAR_ENABLE=1\n' > "$PP_STATE_DIR/config/user.env"
  unset PP_OAR_ENABLE
  printf 'hash-persist' > "$PP_CACHE_DIR/cc-monitor-injected-hash-persist.1-ENGINEERING.txt"
  run bash -c "printf '{\"session_id\":\"persist.1\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  [ -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
  jq -e '.session_id == "persist.1" and .lens == "ENGINEERING"' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
}

@test "session-end: hostile session_id is sanitized before file matching" {
  export PP_OAR_ENABLE=1
  printf 'hash-safe' > "$PP_CACHE_DIR/cc-monitor-injected-hash-....x-SECURITY.txt"
  run bash -c "printf '{\"session_id\":\"../../x*\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  [ -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
  jq -e '.session_id == "....x" and .lens == "SECURITY"' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
}

@test "session-end: latency under 50ms when disabled (p99)" {
  unset PP_OAR_ENABLE
  local _start _end
  _start=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
  bash -c "printf '{\"session_id\":\"s1\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  _end=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
  local _ms=$(( (_end - _start) / 1000000 ))
  [ "$_ms" -lt 50 ]
}

# === v0.5.2: schema extension (Task 2) ===
# Plan addendum C2 fix path A: SessionEnd writes attempts, status, body,
# cited_paths, cited_symbols so the labeler is a pure function of pending
# rows (no filesystem coupling on rotated observation files).

@test "session-end: emitted record carries attempts:0 and status:\"pending\"" {
  printf 'ENG: refactor pp_oar_foo|||The pp_oar_foo function in lib/oar.sh needs hardening.\n' \
    > "$PP_CACHE_DIR/cc-monitor-s2-ENGINEERING.txt"
  printf 'hash-a1' > "$PP_CACHE_DIR/cc-monitor-injected-hash-s2-ENGINEERING.txt"
  export PP_OAR_ENABLE=1
  run bash -c "printf '{\"session_id\":\"s2\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  [ -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
  jq -e '.attempts == 0 and .status == "pending"' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
}

@test "session-end: schema has all 7 baseline fields + 3 v0.5.2 fields" {
  printf 'SEC: review credentials|||content with symbols pp_check_creds and paths lib/sec.sh\n' \
    > "$PP_CACHE_DIR/cc-monitor-s3-SECURITY.txt"
  printf 'hash-b2' > "$PP_CACHE_DIR/cc-monitor-injected-hash-s3-SECURITY.txt"
  export PP_OAR_ENABLE=1
  run bash -c "printf '{\"session_id\":\"s3\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  # Baseline 5 + v0.5.2 additions: attempts, status, body, cited_paths, cited_symbols.
  jq -e '
    has("session_id") and has("lens") and has("hash")
    and has("inject_ts") and has("scan_at_epoch")
    and has("attempts") and has("status")
    and has("body") and has("cited_paths") and has("cited_symbols")
  ' "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
}

# PM2 — schema contract test (mandatory per plan addendum). Asserts the
# pending row carries the exact fields the labeler (Task 8) consumes. This
# is the test that prevents the silent-zero regression where SessionEnd
# writes a schema the labeler can't actually use.
@test "v0.5.2 PM2 contract: oar-pending row matches labeler's expected input shape" {
  printf 'ENG: harden labeler|||The pp_oar_label_pending function in lib/oar.sh needs hardening.\n' \
    > "$PP_CACHE_DIR/cc-monitor-sess-pm2-ENGINEERING.txt"
  printf 'hash-pm2' > "$PP_CACHE_DIR/cc-monitor-injected-hash-sess-pm2-ENGINEERING.txt"
  export PP_OAR_ENABLE=1
  run bash -c "printf '{\"session_id\":\"sess-pm2\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  # Per fix path A: pending row must carry body + cite arrays.
  jq -e 'has("body") and has("cited_paths") and has("cited_symbols")' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
  # Cite arrays must be JSON arrays, not strings.
  jq -e '(.cited_paths | type) == "array" and (.cited_symbols | type) == "array"' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
  # Body extraction: the `LENS: title|||body` line should yield the body
  # portion. Assert the body is non-empty AND does NOT include the title.
  jq -e '.body | test("hardening")' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
  jq -e '.body | test("ENG: harden labeler") | not' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
  # Cited paths + symbols must surface what the labeler will scan against.
  # The body cites lib/oar.sh (path) and pp_oar_label_pending (symbol).
  jq -e '.cited_paths | index("lib/oar.sh") != null' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
  jq -e '.cited_symbols | index("pp_oar_label_pending") != null' \
    "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
}

@test "session-end: cite arrays are JSON arrays even when observation file is missing" {
  # Hash file present, observation file absent — pending row still written
  # but with empty body + empty cite arrays (NOT string defaults).
  printf 'hash-missing' > "$PP_CACHE_DIR/cc-monitor-injected-hash-s4-UX_DESIGN.txt"
  export PP_OAR_ENABLE=1
  run bash -c "printf '{\"session_id\":\"s4\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  jq -e '
    .body == "" and
    (.cited_paths | type) == "array" and
    (.cited_symbols | type) == "array" and
    (.cited_paths | length) == 0 and
    (.cited_symbols | length) == 0
  ' "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
}

@test "session-end: silent-v2 verdict sidecar produces silent pending row" {
  cat > "$PP_CACHE_DIR/cc-monitor-s5-UX_DESIGN-verdict.txt" <<'EOF'
lens0: SILENT -- lens gate found no eligible surface
# v2: schema_version=2
# v2: outcome=silent
# v2: silent_reason=no_eligible_surface
EOF
  export PP_OAR_ENABLE=1
  run bash -c "printf '{\"session_id\":\"s5\"}' | bash '$PP_ROOT/hooks/session-end.sh'"
  [ "$status" -eq 0 ]
  [ -f "$PP_CACHE_DIR/oar-pending.jsonl" ]
  jq -e '
    .session_id == "s5"
    and .lens == "UX_DESIGN"
    and .outcome == "silent"
    and .silent_reason == "no_eligible_surface"
    and .body == ""
    and (.cited_paths | length) == 0
    and (.cited_symbols | length) == 0
    and .status == "pending"
    and .attempts == 0
    and (.scan_at_epoch | type) == "number"
    and (.hash | length) > 0
  ' "$PP_CACHE_DIR/oar-pending.jsonl" >/dev/null
}
