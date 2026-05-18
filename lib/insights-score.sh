#!/usr/bin/env bash
# Pair Polymath - deterministic advisory usefulness/noise scoring.

if [ -n "${_PP_INSIGHTS_SCORE_SOURCED:-}" ]; then
  if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    return 0
  else
    exit 0
  fi
fi
_PP_INSIGHTS_SCORE_SOURCED=1

_pp_insights_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if ! command -v pp_project_id >/dev/null 2>&1; then
  # shellcheck source=project-identity.sh
  . "${_pp_insights_self_dir}/project-identity.sh" 2>/dev/null || true
fi
if ! command -v pp_memory_redact_body >/dev/null 2>&1; then
  # shellcheck source=memory/redact.sh
  . "${_pp_insights_self_dir}/memory/redact.sh" 2>/dev/null || true
fi

pp_insights_score_file() {
  printf '%s/insights/score.jsonl' "${PP_STATE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath}"
}

_pp_insights_epoch() {
  local _ts="${1:-}"
  date -u -d "$_ts" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_ts" +%s 2>/dev/null \
    || printf '0'
}

_pp_insights_lower() {
  LC_ALL=C printf '%s' "${1:-}" | LC_ALL=C tr 'A-Z' 'a-z'
}

_pp_insights_has_grounding() {
  local _body="${1:-}" _paths_json="${2:-[]}" _symbols_json="${3:-[]}" _n
  _n=$(printf '%s' "$_paths_json" | jq 'length' 2>/dev/null || printf '0')
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  [ "$_n" -gt 0 ] && return 0
  _n=$(printf '%s' "$_symbols_json" | jq 'length' 2>/dev/null || printf '0')
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  [ "$_n" -gt 0 ] && return 0
  printf '%s' "$_body" | LC_ALL=C grep -Eq '([A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,8}|[A-Za-z_][A-Za-z0-9_]{3,}[[:space:]]*\('
}

_pp_insights_has_action() {
  local _txt
  _txt=$(_pp_insights_lower "${1:-}")
  printf '%s' "$_txt" | LC_ALL=C grep -Eq '\b(run|fix|add|remove|update|verify|decide|choose|ship|test|measure|inspect|refactor|document|review|guard|gate|audit|capture|compare)\b'
}

_pp_insights_weak_claim() {
  local _txt
  _txt=$(_pp_insights_lower "${1:-}")
  printf '%s' "$_txt" | LC_ALL=C grep -Eq '\b(maybe|might|could|appears|unverified|unclear|probably|possibly|seems|guess|speculative)\b'
}

_pp_insights_redacted_snippet() {
  local _body="${1:-}" _redacted
  if command -v pp_memory_redact_body >/dev/null 2>&1; then
    _redacted=$(pp_memory_redact_body "$_body" 2>/dev/null || printf '%s' "$_body")
  else
    _redacted="$_body"
  fi
  printf '%s' "$_redacted" | LC_ALL=C tr '\r\n\t' '   ' | LC_ALL=C cut -c1-180
}

_pp_insights_append_source() {
  local _source_file="$1" _source_name="$2" _tmp="$3"
  [ -s "$_source_file" ] || return 0
  jq -R 'fromjson?' "$_source_file" 2>/dev/null \
    | jq -c --arg source_dataset "$_source_name" '
        select(type == "object")
        | . + {source_dataset:$source_dataset}
      ' >> "$_tmp" 2>/dev/null || true
}

pp_insights_score() {
  local _window_days="${1:-7}" _json="${2:-0}" _all_projects="${3:-0}"
  case "$_window_days" in ''|*[!0-9]*|0) _window_days=7 ;; esac
  local _now _cutoff
  _now=$(date +%s 2>/dev/null || printf '0')
  case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
  _cutoff=$(( _now - (_window_days * 86400) ))

  local _cache_dir _live _bootstrap _score_file _score_dir
  _cache_dir="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
  _live="${_cache_dir}/oar-labeled.jsonl"
  _bootstrap="${PP_STATE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath}/oar/bootstrap-labeled.jsonl"
  _score_file=$(pp_insights_score_file)
  _score_dir=$(dirname "$_score_file")
  mkdir -p "$_score_dir" 2>/dev/null || return 1

  local _project_id
  _project_id=""
  if command -v pp_project_id >/dev/null 2>&1; then
    _project_id=$(pp_project_id "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || printf '')
  fi

  local _raw_tmp _norm_tmp _topics_tmp _scores_tmp
  _raw_tmp=$(mktemp "${_score_file}.raw.XXXXXX" 2>/dev/null) || return 1
  _norm_tmp=$(mktemp "${_score_file}.norm.XXXXXX" 2>/dev/null) || { rm -f "$_raw_tmp"; return 1; }
  _topics_tmp=$(mktemp "${_score_file}.topics.XXXXXX" 2>/dev/null) || { rm -f "$_raw_tmp" "$_norm_tmp"; return 1; }
  _scores_tmp=$(mktemp "${_score_file}.scores.XXXXXX" 2>/dev/null) || { rm -f "$_raw_tmp" "$_norm_tmp" "$_topics_tmp"; return 1; }

  _pp_insights_append_source "$_live" "live_oar" "$_raw_tmp"
  _pp_insights_append_source "${_live}.1" "live_oar" "$_raw_tmp"
  _pp_insights_append_source "$_bootstrap" "bootstrap_oar" "$_raw_tmp"

  local _line _ts _epoch _row_project_id _lens _topic _body _source_dataset _outcome _confidence
  local _paths_json _symbols_json _identity _body_hash _topic_hash _evidence_ref
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _ts=$(printf '%s' "$_line" | jq -r '.labeled_at // .ts // .inject_ts // ""' 2>/dev/null)
    _epoch=$(_pp_insights_epoch "$_ts")
    case "$_epoch" in ''|*[!0-9]*) _epoch=0 ;; esac
    [ "$_epoch" -lt "$_cutoff" ] && continue
    _row_project_id=$(printf '%s' "$_line" | jq -r '.project_id // ""' 2>/dev/null)
    if [ "$_all_projects" != "1" ] && [ -n "$_project_id" ]; then
      [ "$_row_project_id" = "$_project_id" ] || continue
    fi
    _lens=$(printf '%s' "$_line" | jq -r '.lens // "UNKNOWN"' 2>/dev/null)
    _topic=$(printf '%s' "$_line" | jq -r '.topic // ""' 2>/dev/null)
    _body=$(printf '%s' "$_line" | jq -r '.evidence // .body // ""' 2>/dev/null)
    [ -n "$_topic" ] || _topic=$(printf '%s' "$_body" | LC_ALL=C cut -c1-80)
    _source_dataset=$(printf '%s' "$_line" | jq -r '.source_dataset // "unknown"' 2>/dev/null)
    _outcome=$(printf '%s' "$_line" | jq -r '.outcome // ""' 2>/dev/null)
    _confidence=$(printf '%s' "$_line" | jq -r '.confidence // ""' 2>/dev/null)
    _paths_json=$(printf '%s' "$_line" | jq -c 'if (.cited_paths | type) == "array" then .cited_paths else [] end' 2>/dev/null || printf '[]')
    _symbols_json=$(printf '%s' "$_line" | jq -c 'if (.cited_symbols | type) == "array" then .cited_symbols else [] end' 2>/dev/null || printf '[]')
    _identity=$(printf '%s' "$_line" | jq -r '.identity // ""' 2>/dev/null)
    [ -n "$_identity" ] || _identity=$(pp_project_hash "${_source_dataset}|${_lens}|${_ts}|${_topic}|${_body}")
    _body_hash=$(pp_project_hash "$_body" | cut -c1-16)
    _topic_hash=$(printf '%s' "$_line" | jq -r '.topic_hash // ""' 2>/dev/null)
    [ -n "$_topic_hash" ] || _topic_hash=$(pp_project_hash "${_lens}|${_topic}" | cut -c1-16)
    _evidence_ref=$(printf '%s' "$_line" | jq -r '
      if (.source_file // "") != "" then ((.source_file|tostring) + ":" + ((.source_line // 0)|tostring))
      elif (.identity // "") != "" then (.identity|tostring)
      else ""
      end' 2>/dev/null)
    printf '%s\n' "$_topic_hash" >> "$_topics_tmp"
    jq -nc \
      --arg ts "$_ts" --argjson epoch "$_epoch" --arg lens "$_lens" \
      --arg topic "$_topic" --arg body "$_body" --arg body_hash "$_body_hash" \
      --arg topic_hash "$_topic_hash" --arg identity "$_identity" \
      --arg source_dataset "$_source_dataset" --arg outcome "$_outcome" \
      --arg confidence "$_confidence" --arg project_id "$_row_project_id" \
      --arg evidence_ref "$_evidence_ref" \
      --argjson cited_paths "$_paths_json" --argjson cited_symbols "$_symbols_json" \
      '{ts:$ts, epoch:$epoch, lens:$lens, topic:$topic, body:$body, body_hash:$body_hash,
        topic_hash:$topic_hash, identity:$identity, source_dataset:$source_dataset,
        outcome:$outcome, confidence:$confidence, project_id:(if $project_id=="" then null else $project_id end),
        evidence_ref:$evidence_ref, cited_paths:$cited_paths, cited_symbols:$cited_symbols}' \
      >> "$_norm_tmp"
  done < "$_raw_tmp"

  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _lens=$(printf '%s' "$_line" | jq -r '.lens' 2>/dev/null)
    _topic=$(printf '%s' "$_line" | jq -r '.topic' 2>/dev/null)
    _body=$(printf '%s' "$_line" | jq -r '.body' 2>/dev/null)
    _topic_hash=$(printf '%s' "$_line" | jq -r '.topic_hash' 2>/dev/null)
    _paths_json=$(printf '%s' "$_line" | jq -c '.cited_paths // []' 2>/dev/null || printf '[]')
    _symbols_json=$(printf '%s' "$_line" | jq -c '.cited_symbols // []' 2>/dev/null || printf '[]')
    _outcome=$(printf '%s' "$_line" | jq -r '.outcome // ""' 2>/dev/null)
    _confidence=$(printf '%s' "$_line" | jq -r '.confidence // ""' 2>/dev/null)
    _row_project_id=$(printf '%s' "$_line" | jq -r '.project_id // ""' 2>/dev/null)
    local _grounding=0 _actionability=0 _novelty=1 _follow=0 _noise=0 _repeated=0
    if _pp_insights_has_grounding "$_body" "$_paths_json" "$_symbols_json"; then _grounding=1; else _noise=$((_noise + 1)); fi
    if _pp_insights_has_action "${_topic} ${_body}"; then _actionability=1; fi
    local _topic_count
    _topic_count=$(LC_ALL=C grep -cxF "$_topic_hash" "$_topics_tmp" 2>/dev/null || printf '0')
    case "$_topic_count" in ''|*[!0-9]*) _topic_count=0 ;; esac
    if [ "$_topic_count" -gt 1 ]; then _novelty=0; _repeated=1; _noise=$((_noise + 1)); fi
    case "$_outcome" in acted|referenced) _follow=1 ;; esac
    case "$_confidence" in legacy_inferred) _noise=$((_noise + 1)) ;; unlabelable) _noise=$((_noise + 2)) ;; esac
    if [ "$_all_projects" = "1" ] && [ -n "$_project_id" ] && [ -n "$_row_project_id" ] && [ "$_row_project_id" != "$_project_id" ]; then
      _noise=$((_noise + 2))
    fi
    if _pp_insights_weak_claim "${_topic} ${_body}"; then _noise=$((_noise + 1)); fi
    local _body_len
    _body_len=$(printf '%s' "$_body" | LC_ALL=C wc -c | tr -d ' ')
    case "$_body_len" in ''|*[!0-9]*) _body_len=0 ;; esac
    [ "$_body_len" -gt 500 ] && _noise=$((_noise + 1))
    local _score _useful _noisy _snippet
    _score=$(( _grounding + _actionability + _novelty + _follow - _noise ))
    _useful=0
    _noisy=0
    [ "$_score" -ge 2 ] && _useful=1
    [ "$_noise" -ge 2 ] || [ "$_score" -lt 1 ] && _noisy=1
    _snippet=$(_pp_insights_redacted_snippet "$_body")
    printf '%s' "$_line" | jq -c \
      --arg snippet "$_snippet" \
      --argjson grounding "$_grounding" \
      --argjson actionability "$_actionability" \
      --argjson novelty "$_novelty" \
      --argjson repeated "$_repeated" \
      --argjson follow_through "$_follow" \
      --argjson noise_risk "$_noise" \
      --argjson useful_score "$_score" \
      --argjson useful_looking "$_useful" \
      --argjson noisy_looking "$_noisy" \
      'del(.body, .cited_paths, .cited_symbols)
       | . + {
          snippet:$snippet,
          scores:{
            grounding:$grounding,
            actionability:$actionability,
            novelty:$novelty,
            repeated:$repeated,
            follow_through:$follow_through,
            noise_risk:$noise_risk,
            useful_score:$useful_score,
            useful_looking:$useful_looking,
            noisy_looking:$noisy_looking
          }
        }' >> "$_scores_tmp" 2>/dev/null || true
  done < "$_norm_tmp"

  mv "$_scores_tmp" "$_score_file" 2>/dev/null || cp "$_scores_tmp" "$_score_file" 2>/dev/null || true
  rm -f "$_raw_tmp" "$_norm_tmp" "$_topics_tmp" "$_scores_tmp" 2>/dev/null || true

  local _summary
  _summary=$(jq -R 'fromjson?' "$_score_file" 2>/dev/null \
    | jq -s --argjson window "$_window_days" --arg project_id "$_project_id" --arg score_file "$_score_file" '
        map(select(type == "object")) as $rows
        | {
            total:($rows | length),
            window_days:$window,
            project_id:(if $project_id=="" then null else $project_id end),
            score_file:$score_file,
            by_lens:(
              $rows
              | sort_by(.lens)
              | group_by(.lens)
              | map({
                  lens:.[0].lens,
                  total:length,
                  useful_looking:(map(select(.scores.useful_looking == 1)) | length),
                  noisy_looking:(map(select(.scores.noisy_looking == 1)) | length),
                  repeated:(map(select(.scores.repeated == 1)) | length),
                  acted_referenced:(map(select(.scores.follow_through == 1)) | length),
                  examples:(sort_by(-.scores.useful_score)[0:3] | map({topic, snippet, useful_score:.scores.useful_score, noise_risk:.scores.noise_risk, evidence_ref}))
                })
            ),
            examples:($rows | sort_by(-.scores.useful_score)[0:5] | map({lens, topic, snippet, useful_score:.scores.useful_score, noise_risk:.scores.noise_risk, evidence_ref}))
          }
      ' 2>/dev/null)
  [ -n "$_summary" ] || _summary='{"total":0,"by_lens":[],"examples":[]}'
  if [ "$_json" = "1" ]; then
    printf '%s\n' "$_summary"
  else
    printf '\nInsight usefulness score (last %s days)\n\n' "$_window_days"
    printf '%s' "$_summary" | jq -r '
      "  Total scored: " + (.total|tostring),
      "  By lens:",
      (.by_lens[]? | "    \(.lens): useful=\(.useful_looking), noisy=\(.noisy_looking), repeated=\(.repeated), acted/referenced=\(.acted_referenced)")
    '
    printf '\n  Score rows: %s\n' "$_score_file"
  fi
}
