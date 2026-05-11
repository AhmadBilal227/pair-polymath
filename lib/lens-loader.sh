#!/usr/bin/env bash
# Pair Polymath — lens loader. Reads lenses/*.json (built-in + user override).
# Sourced by bin/statusline.sh. Requires PP_ROOT + jq.
#
# Resolution: built-in lenses from $PP_ROOT/lenses/, then user lenses from
# $HOME/.claude/pair-polymath/lenses/. User lenses with matching `id` OVERRIDE
# built-ins. Sort order: display_order ascending.

# Populates these globals:
#   PP_LENS_COUNT       — integer
#   PP_LENS_IDS         — array of ids (e.g. UX_DESIGN, ENGINEERING, ...)
#   PP_LENS_HATS        — array of comma-joined hats per lens
#   PP_LENS_FOCUS       — array of focus strings per lens
#   PP_LENS_COLOR       — array of color_hex per lens
#   PP_LENS_ENABLED     — array of "true"/"false" per lens

pp_load_lenses() {
  local builtin_dir="$PP_ROOT/lenses"
  local user_dir="$HOME/.claude/pair-polymath/lenses"
  local tmp
  tmp=$(mktemp)

  # Collect: built-ins first, then user (later wins on id)
  {
    [ -d "$builtin_dir" ] && find "$builtin_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null
    [ -d "$user_dir" ]    && find "$user_dir"    -maxdepth 1 -name '*.json' -type f 2>/dev/null
  } | while IFS= read -r f; do
    jq -r --arg src "$f" '
      [.display_order, .id, (.hats|join(",")), .focus, .color_hex, (.enabled // true | tostring), $src]
      | @tsv
    ' "$f" 2>/dev/null
  done > "$tmp"

  # Dedupe by id (last entry wins — user overrides built-in)
  # then sort by display_order
  PP_LENS_IDS=()
  PP_LENS_HATS=()
  PP_LENS_FOCUS=()
  PP_LENS_COLOR=()
  PP_LENS_ENABLED=()

  local awk_out
  awk_out=$(awk -F'\t' '
    {
      id = $2
      data[id] = $0
      order[id] = $1
    }
    END {
      for (id in data) print order[id] "\t" data[id]
    }
  ' "$tmp" | sort -n | cut -f2-)

  while IFS=$'\t' read -r order id hats focus color enabled src; do
    [ -z "$id" ] && continue
    [ "$enabled" = "false" ] && continue
    PP_LENS_IDS+=("$id")
    PP_LENS_HATS+=("$hats")
    PP_LENS_FOCUS+=("$focus")
    PP_LENS_COLOR+=("$color")
    PP_LENS_ENABLED+=("$enabled")
  done <<< "$awk_out"

  PP_LENS_COUNT="${#PP_LENS_IDS[@]}"
  rm -f "$tmp"
}
