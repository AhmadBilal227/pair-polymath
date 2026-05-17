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
      # v0.5.1.1 Stage D - eligibility block. Flatten any_of[].globs
      # into one \x1f-joined glob list. Each any_of entry may carry
      # kind=path_glob (with globs) or kind=always (no globs). If ANY
      # entry has kind=always, the lens is always-eligible (short-
      # circuit at eval time; we emit "always" in the kind column to
      # flag it). Missing block defaults to "always" (back-compat for
      # user lenses without the new key - do not silently disable).
      (.eligibility.any_of // []) as $eg
      | (if ($eg | map(.kind) | index("always")) then "always"
         elif ($eg | length) > 0 then "path_glob"
         else "always" end) as $kind
      | (if $kind == "path_glob"
         then ($eg | map(.globs // []) | add | join(""))
         else "" end) as $globs_joined
      | [
        .display_order,
        .id,
        (.hats|join(",")),
        .focus,
        .color_hex,
        ((if (.enabled == null) then true else .enabled end) | tostring),
        ((.extras.system_prompt_addition // "") | b64),
        ((.extras.examples // []) | join("\n") | b64),
        ((.extras.silent_example // "") | b64),
        ((.extras.silent_reasons // []) | join("") | b64),
        $kind,
        ($globs_joined | b64),
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
  PP_LENS_SILENT_REASONS=()
  # v0.5.1.1 Stage D — eligibility cache (parallel arrays, populated below).
  # KIND: "always" | "path_glob" — short-circuit marker for the evaluator.
  # GLOBS: raw glob list, \x1f-joined (for debugging + accessor).
  # REGEXES: pre-converted ERE regexes, \x1f-joined (one per glob). The
  # converter runs ONCE here (per lens-load), never per-cycle.
  PP_LENS_ELIGIBILITY_KIND=()
  PP_LENS_ELIGIBILITY_GLOBS=()
  PP_LENS_ELIGIBILITY_REGEXES=()

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
  while IFS=$'\x1f' read -r order id hats focus color enabled sys_b64 ex_b64 silent_b64 silent_reasons_b64 elig_kind elig_globs_b64 src; do
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
    local silent_reasons=""
    if [ -n "$silent_reasons_b64" ]; then
      silent_reasons=$(printf '%s' "$silent_reasons_b64" | base64 -d 2>/dev/null)
    fi
    PP_LENS_SILENT_REASONS+=("$silent_reasons")

    # v0.5.1.1 Stage D — eligibility block. kind: always | path_glob.
    # Default to "always" if jq emitted empty (back-compat for user lenses
    # without the new key). Globs are \x1f-joined; convert each to ERE
    # regex ONCE here (cached per lens). Empty globs string + kind=always
    # => empty regex array; eligibility evaluator short-circuits on kind.
    local eligibility_globs="" eligibility_regexes="" g reg
    if [ -z "$elig_kind" ]; then elig_kind="always"; fi
    if [ -n "$elig_globs_b64" ]; then
      eligibility_globs=$(printf '%s' "$elig_globs_b64" | base64 -d 2>/dev/null)
    fi
    if [ -n "$eligibility_globs" ] && [ "$elig_kind" = "path_glob" ]; then
      while IFS= read -r g; do
        [ -z "$g" ] && continue
        reg=$(pp_lens_glob_to_regex "$g")
        if [ -z "$eligibility_regexes" ]; then
          eligibility_regexes="$reg"
        else
          eligibility_regexes="${eligibility_regexes}$(printf '\x1f')${reg}"
        fi
      done <<EOF
$(printf '%s' "$eligibility_globs" | tr $'\x1f' '\n')
EOF
    fi
    PP_LENS_ELIGIBILITY_KIND+=("$elig_kind")
    PP_LENS_ELIGIBILITY_GLOBS+=("$eligibility_globs")
    PP_LENS_ELIGIBILITY_REGEXES+=("$eligibility_regexes")

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

# v0.5.1.1 Stage D — pp_lens_glob_to_regex
# ============================================================================
#
# Convert a single glob pattern to an anchored bash ERE regex.
# Per spec R3 conversion table (docs/v0.5.1.1-planner-grounding-fix-spec.md):
#
#   **/       => (.*/)?         (zero-or-more path components, optionally)
#   **        => .*             (anything across directory boundaries)
#   *         => [^/]*          (anything except /)
#   ?         => [^/]           (single char, not /)
#   {a,b,c}   => (a|b|c)        (brace expansion, NO nesting)
#   . + ( ) [ ] ^ $ | \         => escaped (literal)
#   everything else             => literal
#
# Anchored ^...$. Negation NOT supported (use silent_reasons enum instead).
# Single-pass — we walk the input once and append to the output, NEVER
# re-scanning a substituted value (mirrors the prompt-loader.sh
# secret-leak-guard invariant).
#
# Bash 3.2 portable. No extglob, no globstar, no third-party tools.
#
# Empty input: returns '^$' (defensive — never returns unbounded regex).
#
# Cost: ~50µs per call on macOS bash 3.2. Cached per lens at load time
# (see PP_LENS_ELIGIBILITY_REGEXES population in pp_load_lenses).
pp_lens_glob_to_regex() {
  local glob="$1"
  if [ -z "$glob" ]; then
    printf '^$'
    return 0
  fi

  local out="^"
  local i=0 len="${#glob}" c c1 c2
  while [ "$i" -lt "$len" ]; do
    c="${glob:$i:1}"
    # Rule 1: '**/' (3 chars) MUST be tested BEFORE '**' (2 chars) BEFORE '*' (1).
    c1="${glob:$((i+1)):1}"
    c2="${glob:$((i+2)):1}"
    if [ "$c" = "*" ] && [ "$c1" = "*" ] && [ "$c2" = "/" ]; then
      out="${out}(.*/)?"
      i=$((i + 3))
      continue
    fi
    if [ "$c" = "*" ] && [ "$c1" = "*" ]; then
      # Rule 2: bare ** (no trailing /)
      out="${out}.*"
      i=$((i + 2))
      continue
    fi
    if [ "$c" = "*" ]; then
      # Rule 3: single *
      out="${out}[^/]*"
      i=$((i + 1))
      continue
    fi
    if [ "$c" = "?" ]; then
      # Rule 4
      out="${out}[^/]"
      i=$((i + 1))
      continue
    fi
    if [ "$c" = "{" ]; then
      # Rule 5: brace expansion. Find matching '}'. Treat commas inside
      # as alternation. NESTED braces are NOT supported (spec invariant);
      # if we ever need them, escape the converter explicitly.
      local j=$((i + 1)) inside=""
      local depth=1
      local cj
      while [ "$j" -lt "$len" ]; do
        cj="${glob:$j:1}"
        if [ "$cj" = "{" ]; then depth=$((depth + 1)); fi
        if [ "$cj" = "}" ]; then
          depth=$((depth - 1))
          if [ "$depth" -eq 0 ]; then break; fi
        fi
        inside="${inside}${cj}"
        j=$((j + 1))
      done
      if [ "$j" -ge "$len" ]; then
        # Unmatched '{' — treat as literal to fail open.
        out="${out}\\{"
        i=$((i + 1))
        continue
      fi
      # Split 'inside' on commas, emit (a|b|c). Inside-alternatives are
      # taken literally (no recursive glob conversion) — this matches the
      # spec table examples and avoids a recursive-substitution attack.
      local pipe_form=""
      local k=0 ilen="${#inside}" ic
      while [ "$k" -lt "$ilen" ]; do
        ic="${inside:$k:1}"
        if [ "$ic" = "," ]; then
          pipe_form="${pipe_form}|"
        else
          pipe_form="${pipe_form}${ic}"
        fi
        k=$((k + 1))
      done
      out="${out}(${pipe_form})"
      i=$((j + 1))
      continue
    fi
    case "$c" in
      '.'|'+'|'('|')'|'['|']'|'^'|'$'|'|'|\\)
        # Rule 6: escape regex metachars (literal). The trailing \\ in the
        # case pattern matches a literal backslash character; bash quoting
        # rules force this form (a quoted single-char "\\" produces a
        # parser ambiguity in 3.2 case lists).
        out="${out}\\${c}"
        ;;
      *)
        # Everything else literal.
        out="${out}${c}"
        ;;
    esac
    i=$((i + 1))
  done
  out="${out}\$"
  printf '%s' "$out"
}

# v0.5.1.1 Stage D — accessors for the eligibility cache.
# All three accept a lens ID (case-sensitive, matches PP_LENS_IDS entries).
# Return 0 on hit + write to stdout; return 1 on unknown id + write empty.

_pp_lens_index_by_id() {
  local target="$1"
  local i
  for i in $(seq 0 $((${PP_LENS_COUNT:-0} - 1))); do
    if [ "${PP_LENS_IDS[$i]}" = "$target" ]; then
      printf '%d' "$i"
      return 0
    fi
  done
  return 1
}

pp_lens_eligibility_kind() {
  local idx
  idx=$(_pp_lens_index_by_id "$1") || return 1
  printf '%s' "${PP_LENS_ELIGIBILITY_KIND[$idx]}"
}

pp_lens_eligibility_globs() {
  local idx
  idx=$(_pp_lens_index_by_id "$1") || return 1
  # Stdout: one glob per line (callers process line-by-line).
  printf '%s' "${PP_LENS_ELIGIBILITY_GLOBS[$idx]}" | tr $'\x1f' '\n'
}

pp_lens_eligibility_regexes() {
  local idx
  idx=$(_pp_lens_index_by_id "$1") || return 1
  # Stdout: one regex per line.
  printf '%s' "${PP_LENS_ELIGIBILITY_REGEXES[$idx]}" | tr $'\x1f' '\n'
}
