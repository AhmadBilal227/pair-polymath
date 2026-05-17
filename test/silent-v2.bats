#!/usr/bin/env bats
# v0.5.1.1 Stage B Task 5 — SILENT-V2: pre-critique recognition + closed enum.
# Flag PP_SILENT_V2_ACTIVE=1 activates; default-0 preserves legacy
# SILENT-as-noop behavior at bin/statusline.sh:~1190 byte-identically.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$PP_TEST_HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$CLAUDE_DIR" "$PP_CACHE_DIR"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/lens-loader.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/silent-v2.sh"
  pp_load_lenses
}

teardown() { rm -rf "$PP_TEST_HOME"; }

# --- lens-loader: silent_reasons parsing ---

@test "lens-loader: PP_LENS_SILENT_REASONS populated for all 7 built-in lenses" {
  for i in $(seq 0 $((PP_LENS_COUNT - 1))); do
    [ -n "${PP_LENS_SILENT_REASONS[$i]}" ] \
      || { echo "lens ${PP_LENS_IDS[$i]} has empty silent_reasons"; return 1; }
  done
}

@test "lens-loader: UX_DESIGN[0] silent_reasons include no_ui_surface" {
  printf '%s\n' "${PP_LENS_SILENT_REASONS[0]}" | tr $'\x1f' '\n' | grep -qx 'no_ui_surface'
}

@test "lens-loader: STRATEGIC_FOUNDER silent_reasons include no_strategic_angle" {
  # always-eligible lenses still need at least one enum value so the
  # validator doesn't reject every SILENT they emit.
  local idx=""
  for i in $(seq 0 $((PP_LENS_COUNT - 1))); do
    [ "${PP_LENS_IDS[$i]}" = "STRATEGIC_FOUNDER" ] && idx=$i && break
  done
  [ -n "$idx" ]
  printf '%s\n' "${PP_LENS_SILENT_REASONS[$idx]}" | tr $'\x1f' '\n' | grep -qx 'no_strategic_angle'
}

# --- SILENT-V2 active (PP_SILENT_V2_ACTIVE=1) ---

@test "silent-v2 ON: bare SILENT → outcome=silent silent_reason=unspecified, returns 0" {
  PP_SILENT_V2_ACTIVE=1 run pp_silent_v2_record_verdict 0 "$PP_CACHE_DIR/v.txt" "SILENT"
  [ "$status" -eq 0 ]
  grep -q '^lens0:[[:space:]]*SILENT[[:space:]]*--' "$PP_CACHE_DIR/v.txt"
  grep -q '# v2: schema_version=2$'        "$PP_CACHE_DIR/v.txt"
  grep -q '# v2: outcome=silent$'          "$PP_CACHE_DIR/v.txt"
  grep -q '# v2: silent_reason=unspecified$' "$PP_CACHE_DIR/v.txt"
}

@test "silent-v2 ON: SILENT: no_ui_surface → silent_reason=no_ui_surface" {
  PP_SILENT_V2_ACTIVE=1 pp_silent_v2_record_verdict 0 "$PP_CACHE_DIR/v.txt" "SILENT: no_ui_surface"
  grep -q '# v2: silent_reason=no_ui_surface$' "$PP_CACHE_DIR/v.txt"
}

@test "silent-v2 ON: bogus reason → DROP with drop_reason_class=invalid_silent_reason" {
  PP_SILENT_V2_ACTIVE=1 pp_silent_v2_record_verdict 0 "$PP_CACHE_DIR/v.txt" "SILENT: i_dont_feel_like_it"
  grep -q '^lens0:[[:space:]]*DROP'             "$PP_CACHE_DIR/v.txt"
  grep -q 'invalid_silent_reason'               "$PP_CACHE_DIR/v.txt"
  grep -q '# v2: outcome=drop$'                 "$PP_CACHE_DIR/v.txt"
  grep -q '# v2: drop_reason_class=invalid_silent_reason$' "$PP_CACHE_DIR/v.txt"
}

@test "silent-v2 ON: real observation → returns 1, NO verdict file written" {
  PP_SILENT_V2_ACTIVE=1 run pp_silent_v2_record_verdict 0 "$PP_CACHE_DIR/v.txt" \
    "UX: Submit button missing loading state|||PaymentForm.tsx onSubmit never disables button."
  [ "$status" -eq 1 ]
  [ ! -f "$PP_CACHE_DIR/v.txt" ]
}

@test "silent-v2 ON: per-lens enum closure — ENGINEERING accepts no_code_surface, rejects no_ui_surface" {
  # ENGINEERING is index 1.
  PP_SILENT_V2_ACTIVE=1 pp_silent_v2_record_verdict 1 "$PP_CACHE_DIR/eng_ok.txt"  "SILENT: no_code_surface"
  PP_SILENT_V2_ACTIVE=1 pp_silent_v2_record_verdict 1 "$PP_CACHE_DIR/eng_bad.txt" "SILENT: no_ui_surface"
  grep -q '# v2: silent_reason=no_code_surface$' "$PP_CACHE_DIR/eng_ok.txt"
  grep -q 'invalid_silent_reason'                "$PP_CACHE_DIR/eng_bad.txt"
}

@test "silent-v2 ON: SECURITY rejects no_strategic_angle (cross-lens enum leakage guard)" {
  # SECURITY is index 2.
  PP_SILENT_V2_ACTIVE=1 pp_silent_v2_record_verdict 2 "$PP_CACHE_DIR/sec.txt" "SILENT: no_strategic_angle"
  grep -q 'invalid_silent_reason' "$PP_CACHE_DIR/sec.txt"
}

# --- SILENT-V2 OFF (legacy path, PP_SILENT_V2_ACTIVE=0) ---

@test "silent-v2 OFF: bare SILENT → returns 1, NO write (caller's legacy noop runs)" {
  PP_SILENT_V2_ACTIVE=0 run pp_silent_v2_record_verdict 0 "$PP_CACHE_DIR/v.txt" "SILENT"
  [ "$status" -eq 1 ]
  [ ! -f "$PP_CACHE_DIR/v.txt" ]
}

@test "silent-v2 OFF: SILENT: no_ui_surface → returns 1, NO write (legacy SILENT-as-noop)" {
  PP_SILENT_V2_ACTIVE=0 run pp_silent_v2_record_verdict 0 "$PP_CACHE_DIR/v.txt" "SILENT: no_ui_surface"
  [ "$status" -eq 1 ]
  [ ! -f "$PP_CACHE_DIR/v.txt" ]
}

@test "silent-v2 OFF: real observation → returns 1, NO write" {
  PP_SILENT_V2_ACTIVE=0 run pp_silent_v2_record_verdict 0 "$PP_CACHE_DIR/v.txt" \
    "UX: hook|||body text long enough to pass the 40-char validator threshold."
  [ "$status" -eq 1 ]
  [ ! -f "$PP_CACHE_DIR/v.txt" ]
}

# --- atomic-write invariant ---

@test "silent-v2 ON: verdict write is atomic (tmp+mv pattern, no half-written file)" {
  PP_SILENT_V2_ACTIVE=1 pp_silent_v2_record_verdict 0 "$PP_CACHE_DIR/v.txt" "SILENT: no_ui_surface"
  [ -f "$PP_CACHE_DIR/v.txt" ]
  [ ! -f "$PP_CACHE_DIR/v.txt.tmp" ]
}
