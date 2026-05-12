#!/usr/bin/env bash
# Pair Polymath — lens loader. Reads lenses/*.json (built-in + user override).
# Sourced by bin/statusline.sh. Requires PP_ROOT + jq.
#
# Resolution: built-in lenses from $PP_ROOT/lenses/, then user lenses from
# $HOME/.claude/pair-polymath/lenses/. User lenses with matching `id` OVERRIDE
# built-ins. Sort order: display_order ascending, id ascending on ties.
# Hard cap: PP_LENS_MAX (default 16) — prevents a stuffed user dir from
# turning a statusline refresh into a parallel-LLM cost bomb.

# Populates these globals:
#   PP_LENS_COUNT                   — integer
#   PP_LENS_IDS                     — array of ids (e.g. UX_DESIGN, ENGINEERING, ...)
#   PP_LENS_HATS                    — array of comma-joined hats per lens
#   PP_LENS_FOCUS                   — array of focus strings per lens
#   PP_LENS_COLOR                   — array of color_hex per lens
#   PP_LENS_ENABLED                 — array of "true"/"false" per lens
#   PP_LENS_SYSTEM_PROMPT_ADDITION  — array of extras.system_prompt_addition strings
#                                     (may be empty for back-compat with old lens files)
#   PP_LENS_EXAMPLES                — array of extras.examples joined with \n separator
#                                     (may be empty for back-compat)

pp_load_lenses() {
  local builtin_dir="$PP_ROOT/lenses"
  local user_dir="$HOME/.claude/pair-polymath/lenses"
  local max="${PP_LENS_MAX:-16}"
  local tmp
  tmp=$(mktemp)

  # Field separator inside the tmp/awk pipeline: tab.
  # `extras.system_prompt_addition` and `extras.examples` may contain tabs,
  # newlines, and quotes; we base64-encode them so they survive the TSV
  # pipeline intact and decode at the very end. (Bash 3.2 lacks reliable
  # mapfile/IFS-newline tricks for arbitrary content, so base64 is the
  # simplest portable choice.)
  #
  # IMPORTANT: in bash `read -r`, when IFS contains only whitespace chars
  # (including tab), consecutive separators are COLLAPSED — so empty
  # extras would shift `src` into the wrong variable. We therefore re-emit
  # the awk-sorted rows with a non-whitespace separator (\x1f) at the read
  # step, preserving empty fields. (Caught by lens-loader.bats override
  # test when extras={}.)
  {
    [ -d "$builtin_dir" ] && find "$builtin_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null
    [ -d "$user_dir" ]    && find "$user_dir"    -maxdepth 1 -name '*.json' -type f 2>/dev/null
  } | while IFS= read -r f; do
    jq -r --arg src "$f" '
      def b64: @base64;
      [
        .display_order,
        .id,
        (.hats|join(",")),
        .focus,
        .color_hex,
        (.enabled // true | tostring),
        ((.extras.system_prompt_addition // "") | b64),
        ((.extras.examples // []) | join("\n") | b64),
        ((.extras.silent_example // "") | b64),
        $src
      ]
      | @tsv
    ' "$f" 2>/dev/null
  done > "$tmp"

  PP_LENS_IDS=()
  PP_LENS_HATS=()
  PP_LENS_FOCUS=()
  PP_LENS_COLOR=()
  PP_LENS_ENABLED=()
  PP_LENS_SYSTEM_PROMPT_ADDITION=()
  PP_LENS_EXAMPLES=()
  PP_LENS_SILENT_EXAMPLE=()

  # Dedupe by id (last entry wins → user overrides built-in), then sort by
  # display_order with id as stable tiebreak. Re-emit with \x1f between
  # fields so the downstream `read` doesn't collapse empty fields.
  local awk_out
  awk_out=$(awk -F'\t' -v OFS=$'\x1f' '
    {
      id = $2
      $1=$1   # force rebuild with new OFS
      data[id] = $0
      order[id] = $1
    }
    END {
      for (id in data) print order[id] OFS id OFS data[id]
    }
  ' "$tmp" | sort -t $'\x1f' -k1,1n -k2,2 | cut -d $'\x1f' -f3-)

  local loaded=0
  while IFS=$'\x1f' read -r order id hats focus color enabled sys_b64 ex_b64 silent_b64 src; do
    [ -z "$id" ] && continue
    [ "$enabled" = "false" ] && continue
    if [ "$loaded" -ge "$max" ]; then
      printf 'pp_load_lenses: lens cap (%s) reached; ignoring remainder\n' "$max" >&2
      break
    fi
    # Decode base64-wrapped extras fields. `printf` + `base64 -d` is portable
    # on macOS (BSD) and Linux (GNU). Empty input → empty output.
    local sys_prompt=""
    local examples=""
    if [ -n "$sys_b64" ]; then
      sys_prompt=$(printf '%s' "$sys_b64" | base64 -d 2>/dev/null)
    fi
    if [ -n "$ex_b64" ]; then
      examples=$(printf '%s' "$ex_b64" | base64 -d 2>/dev/null)
      # Bake header into value so back-compat lenses without examples don't
      # render a dangling 'EXAMPLES OF VALID OUTPUT FORMAT:' header.
      if [ -n "$examples" ]; then
        examples="EXAMPLES OF VALID OUTPUT FORMAT (HAT: hook|||body — exact shape):
$examples"
      fi
    fi
    local silent_example=""
    if [ -n "$silent_b64" ]; then
      silent_example=$(printf '%s' "$silent_b64" | base64 -d 2>/dev/null)
      if [ -n "$silent_example" ]; then
        silent_example="WHEN TO OUTPUT 'SILENT' instead (example pattern for this lens):
$silent_example"
      fi
    fi
    PP_LENS_IDS+=("$id")
    PP_LENS_HATS+=("$hats")
    PP_LENS_FOCUS+=("$focus")
    PP_LENS_COLOR+=("$color")
    PP_LENS_ENABLED+=("$enabled")
    PP_LENS_SYSTEM_PROMPT_ADDITION+=("$sys_prompt")
    PP_LENS_EXAMPLES+=("$examples")
    PP_LENS_SILENT_EXAMPLE+=("$silent_example")
    loaded=$((loaded + 1))
  done <<< "$awk_out"

  PP_LENS_COUNT="${#PP_LENS_IDS[@]}"
  rm -f "$tmp"

  if [ "$PP_LENS_COUNT" -eq 0 ]; then
    printf 'pp_load_lenses: no lenses loaded (checked %s and %s)\n' "$builtin_dir" "$user_dir" >&2
    return 1
  fi
  return 0
}
