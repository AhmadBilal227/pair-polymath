#!/usr/bin/env bats
# v0.5.1.1 Stage A — verdict file gains schema_version header + per-invocation
# hash trailer. Spec task 3. v1 parsers must continue working (the `#`
# lines are comments to grep -E '^lens[0-9]+:').
#
# Stage C back-patch (2026-05-17): writer now emits DUAL canonical_
# allowlist_sha8 fields (prompt-side + validator-side) so doctor check #22
# (drift_count invariant) has real signal. Field shape:
#   # v2: canonical_allowlist_sha8_prompt=<8hex>
#   # v2: canonical_allowlist_sha8_validator=<8hex>
#   # v2: rendered_prompt_sha8=<8hex> silent_reason=<reason|empty>

setup() {
  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export CLAUDE_DIR PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}
teardown() { rm -rf "$HOME"; }

# Helper: synthesize the v2 verdict file the way the writer in
# bin/statusline.sh's _pp_write_verdict_v2 does, without running the
# whole statusline cycle.
_write_v2_verdict() {
  local _file="$1" _body="$2" _pcan="$3" _vcan="$4" _rend="$5" _silent="$6"
  {
    printf '# schema_version: 2\n'
    printf '%s\n' "$_body"
    printf '# v2: canonical_allowlist_sha8_prompt=%s\n' "$_pcan"
    printf '# v2: canonical_allowlist_sha8_validator=%s\n' "$_vcan"
    printf '# v2: rendered_prompt_sha8=%s silent_reason=%s\n' "$_rend" "$_silent"
  } > "$_file"
}

@test "verdict v2: file has schema_version header on line 1" {
  local _f="$PP_CACHE_DIR/cc-monitor-test-ENGINEERING-verdict.txt"
  _write_v2_verdict "$_f" "lens0: PASS — concrete" "abc12345" "abc12345" "def67890" ""
  local _first
  _first=$(head -1 "$_f")
  [ "$_first" = "# schema_version: 2" ]
}

@test "verdict v2: v1 parser pattern still picks the lens line" {
  local _f="$PP_CACHE_DIR/cc-monitor-test-SECURITY-verdict.txt"
  _write_v2_verdict "$_f" "lens0: DROP — citation fails: lib/auth.ts not in allowlist" \
    "11112222" "11112222" "33334444" "no_eligible_surface"
  # The today-parser at bin/statusline.sh uses
  #   grep -E "^lens${ci}:" | head -1
  # which must still find the lens line regardless of the surrounding
  # `# schema_version:` and `# v2:` comment lines.
  local _line
  _line=$(grep -E '^lens0:' "$_f" | head -1)
  [ "$_line" = "lens0: DROP — citation fails: lib/auth.ts not in allowlist" ]
}

@test "verdict v2: trailer contains DUAL canonical hashes + rendered hash as 8 hex chars each" {
  local _f="$PP_CACHE_DIR/cc-monitor-test-UX-verdict.txt"
  _write_v2_verdict "$_f" "lens0: PASS" "deadbeef" "deadbeef" "cafef00d" ""
  # Each field lives on its own `# v2:` line so a fixed regex can parse it.
  grep -Eq '^# v2: canonical_allowlist_sha8_prompt=[0-9a-f]{8}$' "$_f"
  grep -Eq '^# v2: canonical_allowlist_sha8_validator=[0-9a-f]{8}$' "$_f"
  grep -Eq '^# v2: rendered_prompt_sha8=[0-9a-f]{8}\b' "$_f"
}

@test "verdict v2: silent_reason field present and parseable when populated" {
  local _f="$PP_CACHE_DIR/cc-monitor-test-PRODUCT-verdict.txt"
  _write_v2_verdict "$_f" "lens0: DROP — no observation" \
    "00000001" "00000001" "00000002" "no_ui_surface"
  # Extract the silent_reason value with a portable shell expansion.
  local _trailer _reason
  _trailer=$(grep -E '^# v2: rendered_prompt_sha8=' "$_f" | head -1)
  _reason=$(printf '%s\n' "$_trailer" \
    | sed -n 's/.*silent_reason=\([^ ]*\).*/\1/p')
  [ "$_reason" = "no_ui_surface" ]
}

@test "verdict v2: empty silent_reason parses as empty string (Stage A always-empty)" {
  # Stage A never populates silent_reason (SILENT recognition lands in
  # Stage B via silent-v2.sh, which doesn't use this writer). The trailer
  # must emit silent_reason= with an empty value, NOT omit the field —
  # keeps the trailer shape stable for v2 readers.
  local _f="$PP_CACHE_DIR/cc-monitor-test-PERF-verdict.txt"
  _write_v2_verdict "$_f" "lens0: PASS" "aaaaaaaa" "aaaaaaaa" "bbbbbbbb" ""
  local _trailer
  _trailer=$(grep -E '^# v2: rendered_prompt_sha8=' "$_f" | head -1)
  # Field name present even though value is empty.
  printf '%s' "$_trailer" | grep -q 'silent_reason='
  # Reason value extracted as empty (no trailing tokens past silent_reason=).
  local _reason
  _reason=$(printf '%s\n' "$_trailer" \
    | sed -n 's/.*silent_reason=\([^ ]*\).*/\1/p')
  [ -z "$_reason" ]
}

@test "verdict v2: prompt and validator hashes IDENTICAL by construction (drift=0 normal case)" {
  # Stage C back-patch contract: the prompt-side rendered inventory and
  # the validator-side allowlist BOTH derive from pp_grounding_symbol_
  # inventory_from_file_read. By construction they must be byte-identical
  # → sha8s match → doctor #22 stays GREEN. A divergence here is the
  # alarm condition the unification pipeline is designed to detect.
  local _f="$PP_CACHE_DIR/cc-monitor-test-IDENT-verdict.txt"
  _write_v2_verdict "$_f" "lens0: PASS" "cafebabe" "cafebabe" "cafebabe" ""
  local _p _v
  _p=$(grep -E '^# v2: canonical_allowlist_sha8_prompt=' "$_f" | sed 's/.*=//')
  _v=$(grep -E '^# v2: canonical_allowlist_sha8_validator=' "$_f" | sed 's/.*=//')
  [ "$_p" = "$_v" ]
  [ "$_p" = "cafebabe" ]
}

@test "verdict v2: writer-function emits dual-hash format end-to-end (back-patch wiring)" {
  # Source the writer directly from statusline.sh by isolating the
  # function definition. The writer is at the top of the file (before
  # the heavy config-loading section), so a head + bash -c works.
  local _writer_src
  _writer_src=$(sed -n '/^_pp_write_verdict_v2()/,/^}$/p' "$PP_ROOT/bin/statusline.sh")
  [ -n "$_writer_src" ]
  local _f="$PP_CACHE_DIR/cc-monitor-test-E2E-verdict.txt"
  bash -c "$_writer_src
_pp_write_verdict_v2 '$_f' 'lens0: PASS — ok' 'feedface' 'feedface' 'deadbeef' ''"
  [ -f "$_f" ]
  # Dual-hash format MUST be present.
  grep -q '^# v2: canonical_allowlist_sha8_prompt=feedface$' "$_f"
  grep -q '^# v2: canonical_allowlist_sha8_validator=feedface$' "$_f"
  grep -q '^# v2: rendered_prompt_sha8=deadbeef silent_reason=$' "$_f"
}

@test "verdict v2: retry-accepted path preserves v2 metadata writer" {
  # Regression: accepted retries briefly overwrote verdict sidecars with a
  # legacy single-line echo, dropping schema/hash trailers for OAR/KPI/drift
  # consumers. Lock in that the retry marker is written through the v2 writer.
  ! grep -qF 'echo "${verdict} (retry accepted)" > "$verdict_file"' "$PP_ROOT/bin/statusline.sh"
  grep -qF '"${verdict} (retry accepted)"' "$PP_ROOT/bin/statusline.sh"
}
