#!/usr/bin/env bash
# Pair Polymath — SILENT-V2 handler (v0.5.1.1, Spec Change 1 / Task 5).
#
# Reads PP_LENS_SILENT_REASONS[lens_idx] populated by lib/lens-loader.sh
# (\x1f-joined enum values). Writes the verdict file in the v2 format
# (legacy first line `lensN: SILENT -- <human>` PLUS `# v2:` appended
# fields that legacy parsers ignore as comments — dual-write schema per
# spec round-3 migration rule).
#
# Function contract:
#   pp_silent_v2_record_verdict <lens_idx> <verdict_file> <lens_output>
#
# Returns:
#   0 — handled (verdict file written OR rejected as invalid_silent_reason
#       and verdict file written with DROP); caller MUST skip the critique
#       call for this lens.
#   1 — not SILENT (real observation OR flag off); caller MUST run the
#       legacy validation + critique path unchanged.
#
# Gating: PP_SILENT_V2_ACTIVE=1 to activate. Default 0 (legacy path).

pp_silent_v2_record_verdict() {
  local _lens_idx="$1"
  local _verdict_file="$2"
  local _output="$3"

  # Legacy fall-through: flag off → caller handles SILENT the old way
  # (line ~1190 noop). We must NOT write the verdict file here.
  if [ "${PP_SILENT_V2_ACTIVE:-0}" != "1" ]; then
    return 1
  fi

  # Not SILENT at all → caller proceeds to normal validate+critique.
  case "$_output" in
    SILENT|"SILENT: "*) : ;;
    *) return 1 ;;
  esac

  local _lens_id="${PP_LENS_IDS[$_lens_idx]}"
  local _reason="unspecified"

  if [ "$_output" != "SILENT" ]; then
    # Extract everything after the first colon, trim surrounding whitespace.
    _reason=$(printf '%s' "$_output" | sed 's/^SILENT:[[:space:]]*//' | tr -d '[:space:]')
    [ -z "$_reason" ] && _reason="unspecified"
  fi

  # Closed-enum check (skipped for the bare-SILENT compat case where
  # _reason stayed 'unspecified' — that's always accepted for v1 compat).
  if [ "$_reason" != "unspecified" ]; then
    local _allowed="${PP_LENS_SILENT_REASONS[$_lens_idx]}"
    local _ok=0
    local _old_ifs="$IFS"
    IFS=$'\x1f'
    local _r
    for _r in $_allowed; do
      [ "$_r" = "$_reason" ] && _ok=1 && break
    done
    IFS="$_old_ifs"
    if [ "$_ok" -ne 1 ]; then
      # Bogus reason: write a DROP verdict so the operator (and OAR
      # labeler) sees this as a contract violation, not a silent accept.
      {
        printf 'lens%s: DROP -- invalid_silent_reason (got %s; lens %s allows %s)\n' \
          "$_lens_idx" "$_reason" "$_lens_id" \
          "$(printf '%s' "$_allowed" | tr $'\x1f' ',')"
        printf '# v2: schema_version=2\n'
        printf '# v2: outcome=drop\n'
        printf '# v2: drop_reason_class=invalid_silent_reason\n'
      } > "${_verdict_file}.tmp" 2>/dev/null \
        && mv "${_verdict_file}.tmp" "$_verdict_file" 2>/dev/null
      return 0
    fi
  fi

  # Valid SILENT — write v2 verdict, atomic.
  {
    printf 'lens%s: SILENT -- lens had no eligible surface (not a failure)\n' "$_lens_idx"
    printf '# v2: schema_version=2\n'
    printf '# v2: outcome=silent\n'
    printf '# v2: silent_reason=%s\n' "$_reason"
  } > "${_verdict_file}.tmp" 2>/dev/null \
    && mv "${_verdict_file}.tmp" "$_verdict_file" 2>/dev/null
  return 0
}
