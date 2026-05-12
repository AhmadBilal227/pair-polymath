#!/usr/bin/env bash
# Pair Polymath — windowed reinforcement signals (Task C).
#
# Four signals tag observations with cheap, post-hoc evidence that they
# "mattered" — the AGENT thinks something is worth remembering, the WORLD
# (git, tests, prior cycles) confirms. Each signal bumps a column on the
# observations table; activation.sh consumes signal_retention via the
# +0.4*retention term, and the other 3 signals feed eviction / display
# logic in later tasks.
#
# ┌────────────────────┬──────────────────────────────────────────────────┐
# │ signal             │ "world said yes" rule                            │
# ├────────────────────┼──────────────────────────────────────────────────┤
# │ retention          │ same (lens,hook) fired THIS cycle AND last cycle │
# │ file_edit          │ cited path appears in git log in next 30 minutes │
# │ commit_mention     │ obs keyword (≥4ch, not stopword) in commit msg   │
# │ test_flip          │ cited path appears in LAST TEST/LINT FAIL block  │
# └────────────────────┴──────────────────────────────────────────────────┘
#
# CONTRACT:
#   pp_memory_tag_retention takes a JSON array of THIS cycle's observations
#   (the cycle controller produces it; we can't recover it from the DB
#   because we need to know which obs fired *this* cycle vs. just exists).
#   The other 3 tag functions scan the DB directly.
#
#   pp_memory_run_signals_post_cycle CWD CURRENT_OBS_JSON
#     — orchestrator that runs all 4 in sequence. Best-effort: a single
#       signal failing never blocks the cycle. Returns 0 unconditionally.
#
#   All multi-statement writes wrap in pp_memory_with_lock at entry. The
#   caller does NOT need to hold the lock.

if [ -z "${PP_ROOT:-}" ]; then
  _pp_memory_signals_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
  PP_ROOT="$_pp_memory_signals_dir"
  unset _pp_memory_signals_dir
fi
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/schema.sh"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/redact.sh"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/memory/lock.sh"

# _pp_signals_is_number VAL
# Local copy of the numeric guard (same shape as the ones in store.sh /
# activation.sh). Duplicated so signals.sh remains independently sourceable.
_pp_signals_is_number() {
  local val="$1"
  case "$val" in
    ''|*[!0-9.-]*) return 1 ;;
  esac
  printf '%s' "$val" | LC_ALL=C grep -qE '^-?[0-9]+(\.[0-9]+)?$'
}

# _pp_signals_mtime FILE
# Stdout: epoch seconds of FILE's mtime. BSD-then-GNU stat fallback (we
# don't have a project-wide pp_mtime helper yet — grounding.sh doesn't
# export one — so inline it here).
_pp_signals_mtime() {
  local f="$1"
  [ -e "$f" ] || return 1
  stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null
}

# _pp_signals_date_plus_30min ISO_TS
# Stdout: ISO_TS + 30 minutes, ISO-8601 UTC. BSD/GNU fallback.
# Accepts BOTH "%Y-%m-%dT%H:%M:%SZ" (pp_memory_insert format) AND
# "%Y-%m-%d %H:%M:%S" (SQLite datetime() format) — tests backdate via
# SQLite, production writes via the insert path, so both shapes appear.
#
# BSD `date` argument order is load-bearing: `-v+30M` must appear AFTER
# `-f INFMT` and BEFORE the input string. The intuitive
# `-f INFMT INPUT -v+30M +OUTFMT` silently *fails parsing*, drops the
# input, and prints the CURRENT date — which is worse than a hard error
# because it looks plausible. Hence the explicit -v-before-input order.
_pp_signals_date_plus_30min() {
  local ts="$1"
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" -v+30M "$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -j -u -f "%Y-%m-%d %H:%M:%S"  -v+30M "$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "$ts + 30 minutes"             +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# _pp_signals_ts_to_epoch ISO_TS
# Stdout: ISO ts → epoch seconds. BSD/GNU fallback. Empty on parse failure.
# Same dual-format handling as _pp_signals_date_plus_30min.
_pp_signals_ts_to_epoch() {
  local ts="$1"
  [ -n "$ts" ] || return 1
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
    || date -j -u -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null \
    || date -u -d "$ts" +%s 2>/dev/null
}

# _pp_signals_normalize_ts TS
# Stdout: TS in canonical "%Y-%m-%dT%H:%M:%SZ" UTC form.
# Accepts the same two input shapes as the helpers above (`...T...Z` from
# pp_memory_insert, `... ...` from SQLite datetime()). All git invocations
# MUST pass the normalized form — git interprets a bare "2026-05-12 12:00:00"
# in LOCAL time, but SQLite produced it in UTC. The 5-hour gap on +0500
# systems silently breaks the 30-minute window check.
_pp_signals_normalize_ts() {
  local ts="$1"
  local epoch
  epoch=$(_pp_signals_ts_to_epoch "$ts") || return 1
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# Stopword list for commit-mention tokenization. Conservative — only words
# that obviously can't carry signal across an obs/commit boundary. Plan
# explicitly enumerated this list; we use it verbatim plus a handful of
# trivial extras commonly seen in commit boilerplate (merge, init, etc.).
_PP_SIGNALS_STOPWORDS=" the this that with from have been were what when where which will would could should about after before because still just then than they them their there more most some such only also into onto upon over under does doing done make made need want take took user users query queries merge init main next prev open close fix fixes fixed work works working test tests added adds adding update updates updating change changes changed remove removes removing "

# _pp_signals_extract_keywords TEXT
# Stdout: newline-delimited keywords from TEXT — lowercase, alphanumeric,
# length ≥4, not in stopword list. Used by commit-mention tagging.
_pp_signals_extract_keywords() {
  local text="$1"
  # Lowercase, replace non-alphanumeric with newline (one token per line).
  # tr in POSIX C locale handles this fine for ASCII; multibyte names are
  # token-split too, which is okay (we'd reject them as <4 chars anyway).
  printf '%s' "$text" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -c 'a-z0-9' '\n' \
    | LC_ALL=C awk -v sw="$_PP_SIGNALS_STOPWORDS" '
        length($0) >= 4 && index(sw, " " $0 " ") == 0 { print $0 }
      ' \
    | LC_ALL=C sort -u
}

# ───────────────────────────── SIGNAL 1: RETENTION ─────────────────────────────

# _pp_signals_retention_inner CWD CURRENT_OBS_JSON
# The body of pp_memory_tag_retention. Factored out so pp_memory_with_lock
# can call it by name (function-name signature, no eval).
_pp_signals_retention_inner() {
  local cwd="$1" current_json="$2"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0

  # Read prior cycle's (lens,hook) pairs. Missing key = empty JSON array.
  local prior_json
  prior_json=$(pp_memory_sqlite "$db" \
    "SELECT value FROM cycle_state WHERE key='prior_obs_lens_hook';" 2>/dev/null)
  [ -z "$prior_json" ] && prior_json='[]'

  # Build current cycle's (lens,hook) projection from the input.
  # jq -c '[.[]|{lens_id,hook}]' gives us a canonical projection we can
  # both (a) write back as the next "prior", and (b) intersect against the
  # existing prior.
  local current_pairs
  current_pairs=$(printf '%s' "$current_json" \
    | jq -c '[.[] | {lens_id: .lens_id, hook: .hook}]' 2>/dev/null) || return 1
  [ -z "$current_pairs" ] && current_pairs='[]'

  # Compute the obs_ids that need a retention bump: any obs whose
  # (lens_id, hook) is present in the prior set. Use jq for the set op so
  # we don't have to do nested-loop string matching in shell.
  #
  # NOTE on `any . == [...]` vs `index([...])`: jq's `index` on an array
  # searches for the argument as a CONTIGUOUS SUBSEQUENCE, not an element.
  # That's a footgun here — we want exact element equality. `any` + `==`
  # is the correct primitive.
  local bump_ids
  bump_ids=$(jq -nc \
    --argjson cur "$current_json" \
    --argjson prior "$prior_json" \
    '
      ($prior | map([.lens_id, .hook])) as $pset
      | [ $cur[]
          | . as $c
          | select( $pset | any(. == [$c.lens_id, $c.hook]) )
          | .obs_id ]
    ' 2>/dev/null) || bump_ids='[]'

  # If anything to bump, write via json_extract pattern. Pass the array
  # through SQLite's json_each — no shell quoting on obs_ids.
  if [ "$(printf '%s' "$bump_ids" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    local payload_tmp
    payload_tmp=$(mktemp "$proj_dir/.retention.XXXXXX") || return 1
    printf '%s\n' "$bump_ids" > "$payload_tmp"
    pp_memory_sqlite "$db" <<SQL
CREATE TEMP TABLE _ids(j TEXT);
.mode list
.import "$payload_tmp" _ids
UPDATE observations
   SET signal_retention = signal_retention + 1
 WHERE obs_id IN (SELECT value FROM _ids, json_each(_ids.j));
SQL
    rm -f "$payload_tmp"
  fi

  # Persist current pairs as the next cycle's "prior". Same JSON
  # round-trip pattern.
  local state_tmp
  state_tmp=$(mktemp "$proj_dir/.priorstate.XXXXXX") || return 1
  printf '%s\n' "$(jq -nc --arg v "$current_pairs" '{v:$v}')" > "$state_tmp"
  pp_memory_sqlite "$db" <<SQL
CREATE TEMP TABLE _ps(j TEXT);
.mode list
.import "$state_tmp" _ps
INSERT OR REPLACE INTO cycle_state(key, value)
SELECT 'prior_obs_lens_hook', json_extract(j, '\$.v') FROM _ps;
SQL
  rm -f "$state_tmp"
  return 0
}

# pp_memory_tag_retention CWD CURRENT_OBS_JSON
# Public entry point — acquires lock then delegates.
pp_memory_tag_retention() {
  local cwd="$1" current_json="$2"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  pp_memory_db_init "$proj_dir"
  pp_memory_with_lock "$proj_dir" _pp_signals_retention_inner "$cwd" "$current_json"
}

# ───────────────────────────── SIGNAL 2: FILE EDIT ─────────────────────────────

# _pp_signals_file_edit_inner CWD
# Scan recent obs whose cited_paths arrays are non-empty and haven't been
# tagged yet. For each cited path, check git log in the 30-minute window
# starting at obs_ts. If touched: bump.
_pp_signals_file_edit_inner() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0
  # Skip if cwd isn't a git repo — file_edit signal is git-only.
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || return 0

  # Snapshot eligible obs to a tempfile (TSV: obs_id<TAB>obs_ts<TAB>paths_json).
  # Window: last 24 hours of activity. file_edit is most useful right after
  # an edit, but we widen to a day so a deferred run (cron, shutdown) still
  # catches things.
  local rows_tmp
  rows_tmp=$(mktemp "$proj_dir/.fileedit.XXXXXX") || return 1
  pp_memory_sqlite -separator '	' "$db" "
    SELECT obs_id, ts, cited_paths FROM observations
     WHERE signal_file_edit = 0
       AND cited_paths IS NOT NULL
       AND cited_paths != '[]'
       AND ts >= datetime('now','-24 hours');
  " > "$rows_tmp" 2>/dev/null

  # Collect ids that need bumping into a JSON array — then a single
  # UPDATE at the end so we don't take many small write txns.
  local bump_ids='[]'
  # NOTE: do not name a local "path" — under zsh `local path=` shadows
  # the special $path array (mirror of $PATH) and breaks PATH lookup in
  # any subshell spawned during the loop. Use pp_p instead. Same pattern
  # already cost us a debugging round in redact.sh; documented in
  # CLAUDE.md gotcha §10.
  local obs_id obs_ts paths_json until_ts pp_p obs_ts_utc
  while IFS=$'\t' read -r obs_id obs_ts paths_json; do
    [ -z "$obs_id" ] && continue
    # Normalize first — git interprets bare "YYYY-MM-DD HH:MM:SS" in LOCAL
    # time but SQLite emits it in UTC. Without normalization the 30min
    # window check silently shifts by TZ offset on every non-UTC machine.
    obs_ts_utc=$(_pp_signals_normalize_ts "$obs_ts")
    [ -z "$obs_ts_utc" ] && continue
    until_ts=$(_pp_signals_date_plus_30min "$obs_ts_utc")
    [ -z "$until_ts" ] && continue
    # Iterate paths in the JSON array via jq -r '.[]'. The shell loop is
    # bounded by the number of cited paths in this obs (≤ a handful).
    local matched=0
    while IFS= read -r pp_p; do
      [ -z "$pp_p" ] && continue
      # Reject any path that escapes cwd. pp_memory_redact_path returns
      # empty for escapes (../ etc).
      local safe_path
      safe_path=$(pp_memory_redact_path "$pp_p" "$cwd")
      [ -z "$safe_path" ] && continue
      # git log --name-only -- PATH prints commit hashes interleaved with
      # touched paths. We use --pretty=format: (empty header) so any
      # non-empty stdout means at least one commit touched the path.
      if [ -n "$(git -C "$cwd" log --since="$obs_ts_utc" --until="$until_ts" \
                    --name-only --pretty=format: -- "$safe_path" 2>/dev/null)" ]; then
        matched=1
        break
      fi
    done < <(printf '%s' "$paths_json" | jq -r '.[]?' 2>/dev/null)
    if [ "$matched" = "1" ]; then
      bump_ids=$(jq -nc --argjson b "$bump_ids" --arg id "$obs_id" \
        '$b + [$id]')
    fi
  done < "$rows_tmp"
  rm -f "$rows_tmp"

  # Single UPDATE for all matched obs_ids.
  if [ "$(printf '%s' "$bump_ids" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    local payload_tmp
    payload_tmp=$(mktemp "$proj_dir/.fileedit-ids.XXXXXX") || return 1
    printf '%s\n' "$bump_ids" > "$payload_tmp"
    pp_memory_sqlite "$db" <<SQL
CREATE TEMP TABLE _ids(j TEXT);
.mode list
.import "$payload_tmp" _ids
UPDATE observations
   SET signal_file_edit = signal_file_edit + 1
 WHERE obs_id IN (SELECT value FROM _ids, json_each(_ids.j));
SQL
    rm -f "$payload_tmp"
  fi
  return 0
}

# pp_memory_tag_file_edit CWD
pp_memory_tag_file_edit() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  pp_memory_db_init "$proj_dir"
  pp_memory_with_lock "$proj_dir" _pp_signals_file_edit_inner "$cwd"
}

# ─────────────────────────── SIGNAL 3: COMMIT MENTION ──────────────────────────

# _pp_signals_commit_mention_inner CWD
_pp_signals_commit_mention_inner() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local rows_tmp
  rows_tmp=$(mktemp "$proj_dir/.cmmention.XXXXXX") || return 1
  pp_memory_sqlite -separator '	' "$db" "
    SELECT obs_id, ts, hook, body FROM observations
     WHERE signal_commit_mention = 0
       AND ts >= datetime('now','-24 hours');
  " > "$rows_tmp" 2>/dev/null

  local bump_ids='[]'
  local obs_id obs_ts hook body obs_ts_utc
  while IFS=$'\t' read -r obs_id obs_ts hook body; do
    [ -z "$obs_id" ] && continue
    obs_ts_utc=$(_pp_signals_normalize_ts "$obs_ts")
    [ -z "$obs_ts_utc" ] && continue
    # Get commit messages since obs_ts (UTC-normalized — see file_edit).
    # Empty stdout = no commits. We don't bound by --until: a mention any
    # time after the obs counts.
    local commits
    commits=$(git -C "$cwd" log --since="$obs_ts_utc" --pretty=format:%B 2>/dev/null)
    [ -z "$commits" ] && continue
    commits=$(printf '%s' "$commits" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    # Extract keywords from hook ∪ body, then check each against commits.
    local matched=0 kw
    while IFS= read -r kw; do
      [ -z "$kw" ] && continue
      # Word-boundary match on lowercased commit text. grep -w treats
      # underscores as part of a word, which is the right behavior for
      # code identifiers (n_plus_one stays one token).
      if printf '%s\n' "$commits" | LC_ALL=C grep -qw -- "$kw"; then
        matched=1
        break
      fi
    done < <(_pp_signals_extract_keywords "$hook $body")
    if [ "$matched" = "1" ]; then
      bump_ids=$(jq -nc --argjson b "$bump_ids" --arg id "$obs_id" \
        '$b + [$id]')
    fi
  done < "$rows_tmp"
  rm -f "$rows_tmp"

  if [ "$(printf '%s' "$bump_ids" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    local payload_tmp
    payload_tmp=$(mktemp "$proj_dir/.cmmention-ids.XXXXXX") || return 1
    printf '%s\n' "$bump_ids" > "$payload_tmp"
    pp_memory_sqlite "$db" <<SQL
CREATE TEMP TABLE _ids(j TEXT);
.mode list
.import "$payload_tmp" _ids
UPDATE observations
   SET signal_commit_mention = signal_commit_mention + 1
 WHERE obs_id IN (SELECT value FROM _ids, json_each(_ids.j));
SQL
    rm -f "$payload_tmp"
  fi
  return 0
}

pp_memory_tag_commit_mention() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  pp_memory_db_init "$proj_dir"
  pp_memory_with_lock "$proj_dir" _pp_signals_commit_mention_inner "$cwd"
}

# ──────────────────────────── SIGNAL 4: TEST FLIP ──────────────────────────────

# _pp_signals_test_flip_inner CWD
_pp_signals_test_flip_inner() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0

  local cache_dir="${PP_CACHE_DIR:-$HOME/.cache/pair-polymath}"
  local cache_file="$cache_dir/last-test-run"
  # Cache absent → noop, success. The signal only fires when there's
  # evidence to consume.
  [ -f "$cache_file" ] || return 0

  # STATUS line. Format documented in Task C spec — "STATUS: FAIL".
  # Avoid `local status` — under zsh, $status is a special read-only
  # mirror of $? and `local status=...` errors with "read-only variable".
  local run_status
  run_status=$(LC_ALL=C grep -E '^STATUS:' "$cache_file" 2>/dev/null \
    | LC_ALL=C awk -F: '{gsub(/^ +| +$/,"",$2); print tolower($2)}' \
    | head -1)
  [ "$run_status" = "fail" ] || return 0

  # Extract FAIL_BLOCK contents.
  local fail_block
  fail_block=$(LC_ALL=C awk '/^FAIL_BLOCK_START/{f=1;next} /^FAIL_BLOCK_END/{f=0} f' \
    "$cache_file" 2>/dev/null)
  [ -z "$fail_block" ] && return 0

  local cache_mtime
  cache_mtime=$(_pp_signals_mtime "$cache_file")
  _pp_signals_is_number "$cache_mtime" || return 0

  local rows_tmp
  rows_tmp=$(mktemp "$proj_dir/.testflip.XXXXXX") || return 1
  pp_memory_sqlite -separator '	' "$db" "
    SELECT obs_id, ts, cited_paths FROM observations
     WHERE signal_test_flip = 0
       AND cited_paths IS NOT NULL
       AND cited_paths != '[]'
       AND ts >= datetime('now','-1 hours');
  " > "$rows_tmp" 2>/dev/null

  local bump_ids='[]'
  # See file_edit re: why we don't `local path` — zsh $path shadowing.
  local obs_id obs_ts paths_json obs_epoch
  while IFS=$'\t' read -r obs_id obs_ts paths_json; do
    [ -z "$obs_id" ] && continue
    obs_epoch=$(_pp_signals_ts_to_epoch "$obs_ts")
    _pp_signals_is_number "$obs_epoch" || continue
    # |cache_mtime - obs_epoch| <= 1800 seconds (30 minutes).
    local delta
    delta=$(( cache_mtime - obs_epoch ))
    [ "$delta" -lt 0 ] && delta=$(( -delta ))
    [ "$delta" -gt 1800 ] && continue
    # Any cited path appears in FAIL_BLOCK?
    local matched=0 pp_p safe_path
    while IFS= read -r pp_p; do
      [ -z "$pp_p" ] && continue
      safe_path=$(pp_memory_redact_path "$pp_p" "$cwd")
      [ -z "$safe_path" ] && continue
      # Fixed-string match — paths often contain regex metachars (dots).
      if printf '%s\n' "$fail_block" | LC_ALL=C grep -qF -- "$safe_path"; then
        matched=1
        break
      fi
    done < <(printf '%s' "$paths_json" | jq -r '.[]?' 2>/dev/null)
    if [ "$matched" = "1" ]; then
      bump_ids=$(jq -nc --argjson b "$bump_ids" --arg id "$obs_id" \
        '$b + [$id]')
    fi
  done < "$rows_tmp"
  rm -f "$rows_tmp"

  if [ "$(printf '%s' "$bump_ids" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    local payload_tmp
    payload_tmp=$(mktemp "$proj_dir/.testflip-ids.XXXXXX") || return 1
    printf '%s\n' "$bump_ids" > "$payload_tmp"
    pp_memory_sqlite "$db" <<SQL
CREATE TEMP TABLE _ids(j TEXT);
.mode list
.import "$payload_tmp" _ids
UPDATE observations
   SET signal_test_flip = signal_test_flip + 1
 WHERE obs_id IN (SELECT value FROM _ids, json_each(_ids.j));
SQL
    rm -f "$payload_tmp"
  fi
  return 0
}

pp_memory_tag_test_flip() {
  local cwd="$1"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 1
  pp_memory_db_init "$proj_dir"
  pp_memory_with_lock "$proj_dir" _pp_signals_test_flip_inner "$cwd"
}

# ──────────────────────────────── ORCHESTRATOR ─────────────────────────────────

# pp_memory_run_signals_post_cycle CWD CURRENT_OBS_JSON
# Runs all 4 signals in sequence. Best-effort: individual signal failures
# never propagate — we never want a tagging hiccup to block the cycle.
# Returns 0 unconditionally.
pp_memory_run_signals_post_cycle() {
  local cwd="$1" current_json="${2:-[]}"
  pp_memory_tag_retention      "$cwd" "$current_json" || true
  pp_memory_tag_file_edit      "$cwd"                 || true
  pp_memory_tag_commit_mention "$cwd"                 || true
  pp_memory_tag_test_flip      "$cwd"                 || true
  return 0
}
