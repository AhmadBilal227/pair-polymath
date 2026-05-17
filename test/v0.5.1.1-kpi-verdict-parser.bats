#!/usr/bin/env bats
# v0.5.1.1 KPI verdict parser regressions.
#
# The statusline writer emits verdict metadata as "# v2:" trailers. These
# tests source the lightweight parser helpers from bin/statusline.sh and pin
# the exact fields consumed by by_lens KPI telemetry.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
  PP_CACHE_DIR="$HOME/.claude/cache"
  mkdir -p "$PP_CACHE_DIR"

  local _helper_src
  _helper_src=$(awk '
    /^_pp_verdict_v2_field\(\)/ { p=1 }
    p { print }
    p && /^}$/ { n += 1; if (n == 5) exit }
  ' "$PP_ROOT/bin/statusline.sh")
  [ -n "$_helper_src" ]
  eval "$_helper_src"
}

teardown() {
  rm -rf "$HOME"
}

@test "kpi verdict parser: drift_count reads v2 dual canonical hashes" {
  local _f="$PP_CACHE_DIR/drift.txt"
  cat > "$_f" <<'EOF'
# schema_version: 2
lens0: PASS -- ok
# v2: canonical_allowlist_sha8_prompt=11111111
# v2: canonical_allowlist_sha8_validator=22222222
# v2: rendered_prompt_sha8=33333333 silent_reason=
EOF

  [ "$(_pp_verdict_kpi_drift_count "$_f")" = "1" ]
}

@test "kpi verdict parser: matching v2 hashes keep drift_count at zero" {
  local _f="$PP_CACHE_DIR/no-drift.txt"
  cat > "$_f" <<'EOF'
# schema_version: 2
lens0: PASS -- ok
# v2: canonical_allowlist_sha8_prompt=aaaaaaaa
# v2: canonical_allowlist_sha8_validator=aaaaaaaa
# v2: rendered_prompt_sha8=bbbbbbbb silent_reason=
EOF

  [ "$(_pp_verdict_kpi_drift_count "$_f")" = "0" ]
}

@test "kpi verdict parser: v2 SILENT lens reason maps to persona_silent bucket" {
  local _f="$PP_CACHE_DIR/persona-silent.txt"
  cat > "$_f" <<'EOF'
lens0: SILENT -- lens had no eligible surface (not a failure)
# v2: schema_version=2
# v2: outcome=silent
# v2: silent_reason=no_ui_surface
EOF

  [ "$(_pp_verdict_kpi_no_eligible_surface_count "$_f")" = "0" ]
  [ "$(_pp_verdict_kpi_persona_silent_count "$_f")" = "1" ]
}

@test "kpi verdict parser: no_eligible_surface stays out of persona_silent bucket" {
  local _f="$PP_CACHE_DIR/no-eligible-surface.txt"
  cat > "$_f" <<'EOF'
lens0: SILENT -- lens gate found no eligible surface
# v2: schema_version=2
# v2: outcome=silent
# v2: silent_reason=no_eligible_surface
EOF

  [ "$(_pp_verdict_kpi_no_eligible_surface_count "$_f")" = "1" ]
  [ "$(_pp_verdict_kpi_persona_silent_count "$_f")" = "0" ]
}

@test "kpi verdict parser: legacy comment markers remain readable" {
  local _f="$PP_CACHE_DIR/legacy.txt"
  cat > "$_f" <<'EOF'
lens0: PASS -- ok
# silent_reason: persona_silent
# canonical_allowlist_sha8: abcd1234
# canonical_allowlist_sha8_validator: dcba4321
EOF

  [ "$(_pp_verdict_kpi_persona_silent_count "$_f")" = "1" ]
  [ "$(_pp_verdict_kpi_drift_count "$_f")" = "1" ]
}
