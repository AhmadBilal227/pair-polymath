#!/usr/bin/env bash
# Pair Polymath - historical OAR bootstrap from Claude session JSONL logs.
#
# Bootstrap rows are advisory evidence only. They are written to
# $PP_STATE_DIR/oar/bootstrap-labeled.jsonl and are never merged into live
# oar-labeled.jsonl.

if [ -n "${_PP_OAR_BOOTSTRAP_SOURCED:-}" ]; then
  if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    return 0
  else
    exit 0
  fi
fi
_PP_OAR_BOOTSTRAP_SOURCED=1

_pp_oar_bootstrap_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if ! command -v pp_project_identity_json >/dev/null 2>&1; then
  # shellcheck source=project-identity.sh
  . "${_pp_oar_bootstrap_self_dir}/project-identity.sh" 2>/dev/null || true
fi
if ! command -v pp_extract_citations_from_text >/dev/null 2>&1; then
  # shellcheck source=citations.sh
  . "${_pp_oar_bootstrap_self_dir}/citations.sh" 2>/dev/null || true
fi

pp_oar_bootstrap_file() {
  printf '%s/oar/bootstrap-labeled.jsonl' "${PP_STATE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath}"
}

pp_oar_bootstrap_default_dir() {
  local _root _slug _base
  _root=$(pp_project_real_root "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}")
  _slug=$(printf '%s' "$_root" | sed 's#/#-#g')
  _base="${CLAUDE_DIR:-$HOME/.claude}/projects"
  if [ -d "${_base}/${_slug}" ]; then
    printf '%s/%s' "$_base" "$_slug"
  else
    printf '%s' "$_base"
  fi
}

_pp_oar_bootstrap_hash12() {
  pp_project_hash "${1:-}" | cut -c1-12
}

_pp_oar_bootstrap_extract() {
  # stdin: advisory content. stdout TSV: lens<TAB>topic<TAB>body
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function emit() {
      if (lens != "") {
        print lens "\t" trim(topic) "\t" trim(body)
      }
      lens=""; topic=""; body=""
    }
    /^\[BACKGROUND ADVISORY/ { in_block=1; next }
    /^\[END BACKGROUND ADVISORY\]/ { emit(); in_block=0; next }
    in_block && /^[A-Za-z][A-Za-z0-9_\/-]*: / {
      emit()
      lens=$0
      sub(/:.*/, "", lens)
      topic=$0
      sub(/^[A-Za-z][A-Za-z0-9_\/-]*:[[:space:]]*/, "", topic)
      if (topic ~ /\|\|\|/) {
        body=topic
        sub(/^.*\|\|\|/, "", body)
        sub(/\|\|\|.*/, "", topic)
      } else {
        body=""
      }
      next
    }
    in_block && lens != "" && /^  / {
      line=$0
      sub(/^  /, "", line)
      if (body == "") body=line
      else body=body " " line
      next
    }
    in_block && lens != "" && /^$/ { emit(); next }
    END { emit() }
  '
}

_pp_oar_bootstrap_content_from_json() {
  jq -r '
    def textify:
      if type == "array" then
        map(if type == "object" then (.text // .content // .value // "") else tostring end) | join("\n")
      elif type == "object" then
        (.text // .content // .value // "")
      else
        tostring
      end;
    (
      .attachment.content
      // .hook_event.content
      // .message.content
      // .content
      // .result
      // ""
    ) | textify
  ' 2>/dev/null
}

_pp_oar_bootstrap_project_json() {
  local _cwd="${1:-}"
  [ -n "$_cwd" ] || _cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
  if command -v pp_project_identity_json >/dev/null 2>&1 && [ -d "$_cwd" ]; then
    pp_project_identity_json "$_cwd" 2>/dev/null || printf '{}'
  else
    pp_project_identity_json "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || printf '{}'
  fi
}

pp_oar_bootstrap_scan() {
  local _dir="${1:-$(pp_oar_bootstrap_default_dir)}"
  local _out
  _out=$(pp_oar_bootstrap_file)
  mkdir -p "$(dirname "$_out")" 2>/dev/null || return 1
  touch "$_out" 2>/dev/null || return 1
  [ -d "$_dir" ] || { printf 'oar bootstrap scan: no session log dir at %s\n' "$_dir" >&2; return 1; }

  local _stats
  _stats=$(mktemp "${_out}.stats.XXXXXX" 2>/dev/null) || return 1
  printf '0\t0\n' > "$_stats"

  local _current_root
  _current_root=$(pp_project_real_root "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}")

  find "$_dir" -type f \( -name '*.jsonl' -o -name '*.json' \) 2>/dev/null | sort | while IFS= read -r _file; do
    [ -n "$_file" ] || continue
    local _line_no=0
    while IFS= read -r _raw || [ -n "$_raw" ]; do
      _line_no=$((_line_no + 1))
      case "$_raw" in *BACKGROUND\ ADVISORY*) ;; *) continue ;; esac
      printf '1\t0\n' >> "$_stats"

      local _content _ts _sid _cwd _prompt_versions_json _project_json
      _content=$(printf '%s' "$_raw" | _pp_oar_bootstrap_content_from_json)
      case "$_content" in *BACKGROUND\ ADVISORY*) ;; *) continue ;; esac
      _ts=$(printf '%s' "$_raw" | jq -r '.timestamp // .created_at // .ts // ""' 2>/dev/null)
      [ -n "$_ts" ] || _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
      _sid=$(printf '%s' "$_raw" | jq -r '.session_id // .sessionId // .session // ""' 2>/dev/null)
      _cwd=$(printf '%s' "$_raw" | jq -r '.cwd // .workspace.current_dir // .project_cwd // ""' 2>/dev/null)
      _prompt_versions_json=$(printf '%s' "$_raw" | jq -c 'if (.prompt_versions | type) == "object" then .prompt_versions else {} end' 2>/dev/null || printf '{}')
      printf '%s' "$_prompt_versions_json" | jq -e 'type == "object"' >/dev/null 2>&1 || _prompt_versions_json="{}"
      _project_json=$(_pp_oar_bootstrap_project_json "$_cwd")

      printf '%s\n' "$_content" | _pp_oar_bootstrap_extract | while IFS="$(printf '\t')" read -r _lens _topic _body; do
        [ -n "$_lens" ] || continue
        local _confidence _row_root _project_id _project_root _project_root_sha8
        _confidence="legacy_inferred"
        if [ -z "$_body" ] || [ -z "$_topic" ]; then
          _confidence="unlabelable"
        elif [ -n "$_cwd" ] && [ -d "$_cwd" ]; then
          _row_root=$(pp_project_real_root "$_cwd" 2>/dev/null || printf '')
          if [ -n "$_row_root" ] && [ "$_row_root" = "$_current_root" ]; then
            _confidence="session_log_inferred"
          else
            _confidence="legacy_inferred"
          fi
        fi
        _project_id=$(printf '%s' "$_project_json" | jq -r '.project_id // empty' 2>/dev/null)
        _project_root=$(printf '%s' "$_project_json" | jq -r '.project_root // empty' 2>/dev/null)
        _project_root_sha8=$(printf '%s' "$_project_json" | jq -r '.project_root_sha8 // empty' 2>/dev/null)

        local _body_hash _topic_hash _identity _cited_paths_json _cited_symbols_json
        _body_hash=$(_pp_oar_bootstrap_hash12 "$_body")
        _topic_hash=$(_pp_oar_bootstrap_hash12 "${_lens}|${_topic}")
        _identity=$(pp_project_hash "${_sid}|${_ts}|${_file}|${_line_no}|${_lens}|${_topic}|${_body_hash}")
        if grep -q "\"identity\":\"$_identity\"" "$_out" 2>/dev/null; then
          continue
        fi
        if command -v pp_extract_citations_from_text >/dev/null 2>&1; then
          pp_extract_citations_from_text "$_body" 2>/dev/null || true
        fi
        _cited_paths_json=$(printf '%s' "${_pp_valid_paths:-}" | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || printf '[]')
        _cited_symbols_json=$(printf '%s' "${_pp_valid_symbols:-}" | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || printf '[]')

        jq -nc \
          --arg schema_version "1" \
          --arg source "session_log_bootstrap" \
          --arg confidence "$_confidence" \
          --arg ts "$_ts" \
          --arg session_id "$_sid" \
          --arg lens "$_lens" \
          --arg topic "$_topic" \
          --arg body "$_body" \
          --arg body_hash "$_body_hash" \
          --arg topic_hash "$_topic_hash" \
          --arg identity "$_identity" \
          --arg source_file "$_file" \
          --argjson source_line "$_line_no" \
          --arg project_cwd "$_cwd" \
          --arg project_id "$_project_id" \
          --arg project_root "$_project_root" \
          --arg project_root_sha8 "$_project_root_sha8" \
          --argjson cited_paths "$_cited_paths_json" \
          --argjson cited_symbols "$_cited_symbols_json" \
          --argjson prompt_versions "$_prompt_versions_json" \
          '{schema_version:($schema_version|tonumber), source:$source, confidence:$confidence,
            ts:$ts, session_id:(if $session_id=="" then null else $session_id end),
            lens:$lens, topic:$topic, body:$body, body_hash:$body_hash,
            topic_hash:$topic_hash, identity:$identity, source_file:$source_file,
            source_line:$source_line, project_cwd:(if $project_cwd=="" then null else $project_cwd end),
            project_id:(if $project_id=="" then null else $project_id end),
            project_root:(if $project_root=="" then null else $project_root end),
            project_root_sha8:(if $project_root_sha8=="" then null else $project_root_sha8 end),
            cited_paths:$cited_paths, cited_symbols:$cited_symbols,
            prompt_versions:$prompt_versions}' >> "$_out" 2>/dev/null || true
        printf '0\t1\n' >> "$_stats"
      done
    done < "$_file"
  done

  local _scanned _written
  _scanned=$(awk -F'\t' '{s+=$1} END{print s+0}' "$_stats" 2>/dev/null)
  _written=$(awk -F'\t' '{s+=$2} END{print s+0}' "$_stats" 2>/dev/null)
  rm -f "$_stats" 2>/dev/null || true
  printf 'oar bootstrap scan: scanned %s advisory-bearing log rows, wrote %s bootstrap rows -> %s\n' \
    "$_scanned" "$_written" "$_out"
}

pp_oar_bootstrap_report() {
  local _json="${1:-0}" _all_projects="${2:-0}" _file _project_id
  _file=$(pp_oar_bootstrap_file)
  _project_id=""
  if command -v pp_project_id >/dev/null 2>&1; then
    _project_id=$(pp_project_id "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || printf '')
  fi
  if [ ! -s "$_file" ]; then
    if [ "$_json" = "1" ]; then
      printf '{"total":0,"by_confidence":{},"by_lens":[]}\n'
    else
      printf 'No bootstrap observations yet. Run: polymath oar bootstrap scan\n'
    fi
    return 0
  fi
  local _summary
  _summary=$(jq -R 'fromjson?' "$_file" 2>/dev/null \
    | jq -s --arg project_id "$_project_id" --argjson all_projects "$_all_projects" '
        map(select(type == "object"))
        | (if ($all_projects == 1 or $project_id == "") then . else map(select(.project_id == $project_id)) end)
        | {
            total:length,
            by_confidence:(sort_by(.confidence // "unknown") | group_by(.confidence // "unknown") | map({key:(.[0].confidence // "unknown"), value:length}) | from_entries),
            by_lens:(sort_by(.lens) | group_by(.lens) | map({lens:.[0].lens, total:length, confidence:(sort_by(.confidence // "unknown") | group_by(.confidence // "unknown") | map({key:(.[0].confidence // "unknown"), value:length}) | from_entries)})),
            examples:(.[0:5] | map({lens, topic, confidence, source_file, source_line}))
          }
      ' 2>/dev/null)
  [ -n "$_summary" ] || _summary='{"total":0,"by_confidence":{},"by_lens":[],"examples":[]}'
  if [ "$_json" = "1" ]; then
    printf '%s\n' "$_summary"
  else
    printf '\nHistorical OAR bootstrap\n\n'
    printf '%s' "$_summary" | jq -r '
      "  Total bootstrap rows: \(.total)",
      "  By confidence:",
      (.by_confidence | to_entries[]? | "    \(.key): \(.value)"),
      "",
      "  By lens:",
      (.by_lens[]? | "    \(.lens): \(.total)")
    '
    printf '\n  Dataset: %s\n' "$_file"
  fi
}
