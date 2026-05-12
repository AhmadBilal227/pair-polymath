#!/usr/bin/env bash
# Pair Polymath — SQLite-backed observation store.
#
# CONTRACT: This file sources lib/grounding.sh + lib/memory/schema.sh +
# lib/memory/redact.sh on load so all the helpers the API surfaces here
# (pp_memory_project_dir, pp_memory_db_init, pp_memory_sqlite,
# pp_memory_redact_body) are available without callers having to know
# the load order.
#
# Inserts use jq-built JSON + SQLite json_extract (no shell-quoting on
# user-supplied body/hook). Top-K retrieval bumps use_count + last_seen_ts
# in the same transaction. Hybrid retrieval (B.3) uses FTS5 BM25 +
# activation_score so retrieval is relevance-aware, not pure-recency.

if [ -z "${PP_ROOT:-}" ]; then
  _pp_memory_store_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
  PP_ROOT="$_pp_memory_store_dir"
  unset _pp_memory_store_dir
fi
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/schema.sh"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/redact.sh"

# _pp_memory_is_number VALUE [MIN]
# Returns 0 if VALUE matches a numeric regex (optional leading minus, digits,
# optional fractional part). With MIN given, also requires VALUE >= MIN.
# Used to defang SQL-injection via numeric interpolation in heredoc queries
# (alpha, k, decay are all interpolated as bare literals).
_pp_memory_is_number() {
  local val="$1" min="${2:-}"
  case "$val" in
    ''|*[!0-9.-]*) return 1 ;;
  esac
  # Anchor: only one optional leading minus, digits, optional single dot
  # followed by digits. Reject "1.2.3", "-", "-.5", etc.
  printf '%s' "$val" | LC_ALL=C grep -qE '^-?[0-9]+(\.[0-9]+)?$' || return 1
  if [ -n "$min" ]; then
    LC_ALL=C awk -v v="$val" -v m="$min" 'BEGIN { exit (v+0 >= m+0 ? 0 : 1) }' || return 1
  fi
  return 0
}

# pp_memory_insert CWD OBS_ID LENS_ID TOPIC HOOK BODY CITED_PATHS_JSON CITED_SYMBOLS_JSON SESSION_ID
# Inserts (or replaces) one observation. Default-on redaction
# (PP_MEMORY_REDACT=1) runs on body before persistence.
pp_memory_insert() {
  local cwd="$1" obs_id="$2" lens="$3" topic="$4" hook="$5"
  local body="$6" paths_json="${7:-[]}" symbols_json="${8:-[]}" sess="$9"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  pp_memory_db_init "$proj_dir"
  local db="$proj_dir/observations.sqlite"
  local phash
  phash=$(pp_memory_project_hash "$cwd")
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local redacted=0
  if [ "${PP_MEMORY_REDACT:-1}" = "1" ]; then
    body=$(pp_memory_redact_body "$body")
    redacted=1
  fi
  # Build a JSON envelope so the body/hook/topic round-trip through SQLite
  # via json_extract — no shell-quoting on user text. paths_json/symbols_json
  # are stored as opaque TEXT (callers pass valid JSON arrays).
  local input
  input=$(jq -nc \
    --arg obs_id "$obs_id" --arg ts "$now" \
    --arg sv "$PP_MEMORY_SCHEMA_VERSION" --arg lens "$lens" \
    --arg topic "$topic" --arg hook "$hook" --arg body "$body" \
    --arg paths "$paths_json" --arg symbols "$symbols_json" \
    --arg phash "$phash" --arg sess "$sess" \
    --argjson red "$redacted" \
    '{obs_id:$obs_id, ts:$ts, sv:$sv, lens:$lens, topic:$topic,
      hook:$hook, body:$body, paths:$paths, symbols:$symbols,
      phash:$phash, sess:$sess, red:$red}')
  # We can't pipe stdin to sqlite3 AND feed it a SQL heredoc — sqlite3 only
  # has one stdin. Write the JSON to a tempfile, then `.import` from there.
  # The tempfile lives in proj_dir (already 0700) and is removed even on
  # SQL error.
  local input_tmp
  input_tmp=$(mktemp "$proj_dir/.insert.XXXXXX") || return 1
  printf '%s\n' "$input" > "$input_tmp"
  local rc=0
  pp_memory_sqlite "$db" <<SQL || rc=$?
CREATE TEMP TABLE _input(j TEXT);
.mode list
.import "$input_tmp" _input
INSERT OR REPLACE INTO observations
  (obs_id, ts, schema_version, lens_id, topic, hook, body,
   cited_paths, cited_symbols, project_hash, session_id,
   last_seen_ts, redacted)
SELECT
  json_extract(j, '\$.obs_id'), json_extract(j, '\$.ts'),
  json_extract(j, '\$.sv'),     json_extract(j, '\$.lens'),
  json_extract(j, '\$.topic'),  json_extract(j, '\$.hook'),
  json_extract(j, '\$.body'),   json_extract(j, '\$.paths'),
  json_extract(j, '\$.symbols'),json_extract(j, '\$.phash'),
  json_extract(j, '\$.sess'),   json_extract(j, '\$.ts'),
  json_extract(j, '\$.red')
FROM _input;
SQL
  rm -f "$input_tmp"
  return "$rc"
}

# pp_memory_top_k CWD K [QUERY_TEXT]
# Returns top-K observations as JSON (one array on stdout via sqlite3 -json).
# - Without QUERY_TEXT: pure activation_score ordering (recency-biased).
# - With QUERY_TEXT: hybrid score = activation_score + α × normalized_bm25
#   where α = PP_MEMORY_RETRIEVAL_ALPHA (default 1.0). Normalization is
#   /max(relevance) so the BM25 term is on the same [0,1] scale as activation.
# In either case bumps use_count + last_seen_ts on the returned rows IN
# THE SAME TRANSACTION (no torn read).
pp_memory_top_k() {
  local cwd="$1" k="${2:-15}" query="${3:-}"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 0
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local alpha="${PP_MEMORY_RETRIEVAL_ALPHA:-1.0}"

  # Numeric validation. These get interpolated into the SQL heredoc as bare
  # literals — any non-numeric string would be a SQL injection vector
  # (e.g. PP_MEMORY_RETRIEVAL_ALPHA='1.0; DROP TABLE observations; --').
  if ! _pp_memory_is_number "$k" 1; then
    printf 'pp_memory_top_k: invalid k=%s (need integer >= 1)\n' "$k" >&2
    return 1
  fi
  # k must also be an integer; reject fractional.
  case "$k" in
    *.*)
      printf 'pp_memory_top_k: k=%s must be integer\n' "$k" >&2
      return 1
      ;;
  esac
  if ! _pp_memory_is_number "$alpha" 0; then
    printf 'pp_memory_top_k: invalid alpha=%s (need float >= 0)\n' "$alpha" >&2
    return 1
  fi

  if [ -n "$query" ]; then
    # Hybrid retrieval. FTS5 bm25() is negative for relevance (lower = better
    # match); we negate so higher = better, normalize by max, then add to
    # activation_score scaled by alpha. LEFT JOIN keeps rows that didn't
    # match the query (they fall through with 0 BM25 contribution).
    #
    # bm25() can ONLY appear in the column-list of a query whose FROM
    # references the FTS5 table directly — putting it in a CTE that's
    # referenced more than once, or in CTAS, raises "unable to use function
    # bm25 in the requested context". We sidestep that by materializing
    # bm25 results into a plain temp table first, then joining in a second
    # query.
    #
    # FTS5 query escaping: strip everything except alphanumerics, underscore,
    # and spaces. We omit dash because FTS5 treats it as a NOT operator and
    # a stray leading/trailing dash raises an "fts5: syntax error near -".
    # Empty-string fallback ("x") prevents FTS5's "no such query syntax"
    # error when the caller passes pure punctuation.
    local q_safe
    q_safe=$(printf '%s' "$query" | LC_ALL=C tr -cd 'A-Za-z0-9_ ' | LC_ALL=C tr -s ' ')
    # Trim leading + trailing whitespace.
    q_safe="${q_safe# }"
    q_safe="${q_safe% }"
    # Defense-in-depth: strip any embedded single quotes (the char class
    # above already excludes them, but a future tweak shouldn't open the door).
    q_safe=${q_safe//\'/}
    # Phrase-quote every token. Without quoting, FTS5 treats bare "OR", "AND",
    # "NOT", "NEAR" as operators — an adversarial query like "kafka NOT" then
    # raises an FTS5 syntax error and aborts the transaction. Quoting each
    # token forces FTS5 to treat them as literal phrases.
    local q_quoted="" tok
    for tok in $q_safe; do
      [ -z "$tok" ] && continue
      if [ -z "$q_quoted" ]; then
        q_quoted="\"$tok\""
      else
        q_quoted="$q_quoted \"$tok\""
      fi
    done
    # If nothing survived, fall through to the pure-activation branch — the
    # FTS5 MATCH with empty/whitespace query is a syntax error.
    if [ -z "$q_quoted" ]; then
      pp_memory_sqlite -json "$db" <<SQL
BEGIN;
CREATE TEMP TABLE _top AS
  SELECT obs_id FROM observations
  ORDER BY (activation_score IS NULL), activation_score DESC, obs_id ASC
  LIMIT $k;
UPDATE observations
  SET use_count = use_count + 1, last_seen_ts = '$now'
  WHERE obs_id IN (SELECT obs_id FROM _top);
SELECT * FROM observations WHERE obs_id IN (SELECT obs_id FROM _top)
  ORDER BY (activation_score IS NULL), activation_score DESC, obs_id ASC;
COMMIT;
SQL
      return $?
    fi
    pp_memory_sqlite -json "$db" <<SQL
BEGIN;
CREATE TEMP TABLE _bm(rowid INTEGER PRIMARY KEY, relevance REAL);
INSERT INTO _bm
  SELECT rowid, -bm25(obs_fts) FROM obs_fts WHERE obs_fts MATCH '${q_quoted}';
CREATE TEMP TABLE _scored AS
  SELECT o.obs_id,
         o.activation_score
         + $alpha * COALESCE(_bm.relevance / NULLIF((SELECT MAX(relevance) FROM _bm), 0), 0)
         AS hybrid_score
  FROM observations o
  LEFT JOIN _bm ON _bm.rowid = o.rowid
  ORDER BY (hybrid_score IS NULL), hybrid_score DESC, o.obs_id ASC
  LIMIT $k;
UPDATE observations
  SET use_count = use_count + 1, last_seen_ts = '$now'
  WHERE obs_id IN (SELECT obs_id FROM _scored);
SELECT o.* FROM observations o
  JOIN _scored s ON s.obs_id = o.obs_id
  ORDER BY (s.hybrid_score IS NULL), s.hybrid_score DESC, o.obs_id ASC;
COMMIT;
SQL
  else
    # Pure activation ranking — no query context provided.
    # ORDER BY (col IS NULL), col DESC is the portable equivalent of
    # "DESC NULLS LAST" (not all SQLite builds compile in NULLS LAST).
    # obs_id ASC is the deterministic tiebreak for identical scores.
    pp_memory_sqlite -json "$db" <<SQL
BEGIN;
CREATE TEMP TABLE _top AS
  SELECT obs_id FROM observations
  ORDER BY (activation_score IS NULL), activation_score DESC, obs_id ASC
  LIMIT $k;
UPDATE observations
  SET use_count = use_count + 1, last_seen_ts = '$now'
  WHERE obs_id IN (SELECT obs_id FROM _top);
SELECT * FROM observations WHERE obs_id IN (SELECT obs_id FROM _top)
  ORDER BY (activation_score IS NULL), activation_score DESC, obs_id ASC;
COMMIT;
SQL
  fi
}
