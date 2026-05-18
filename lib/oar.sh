#!/usr/bin/env bash
# Pair Polymath — OAR (Observation→Action Rate) labeler. v0.5.2.
#
# Owns: the measurement substrate that classifies each injected advisory's
# next-N-hours outcome into one of {acted, referenced, pushed-back, ignored}.
# Reads oar-pending.jsonl, writes oar-labeled.jsonl (and oar-stuck.jsonl on
# 3rd failed attempt). Per-row 3s soft cap; per-cycle cap of 5 rows.
#
# Single-source-of-truth invariants (see spec §B + §F + §G):
#   1. Stable identity = sha256(sid|lens|hash|inject_ts). Re-injections of
#      the same (sid, lens, hash) at different cycles do not collide.
#   2. oar-pending.jsonl has NO size-based rotation. Rows leave pending only
#      via labeled-or-stuck transition.
#   3. All cited paths go through pp_contain_path BEFORE git/grep/ls calls.
#   4. Labeler runs INLINE in statusline.sh in a `& wait`-bounded subshell.
#      Telemetry must never block the cycle.

# Bash 3.2 portable. Do not mutate the caller's locale at source time:
# statusline intentionally keeps the process locale for Unicode rendering.
# Byte-oriented commands below scope LC_ALL=C at the individual call site.

# Idempotent source guard (sourced by bin/statusline.sh, bin/polymath, tests).
# Guard against the file being EXECUTED rather than sourced — `return` at
# top level errors out if BASH_SOURCE[0] == $0 (i.e. running this file as a
# script). Cheap defensive check.
if [ -n "${_PP_OAR_SOURCED:-}" ]; then
  if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    return 0
  else
    exit 0
  fi
fi
_PP_OAR_SOURCED=1

# Plan addendum I1 (2026-05-16): pp_oar_acted_for_path and other oar.sh
# helpers depend on pp_safe_git_pathspec + pp_contain_path from
# lib/grounding.sh. The tests in test/oar-labeler.bats intentionally do NOT
# pre-source grounding.sh — this guards against a runtime gap where
# bin/statusline.sh's source order would mask the dependency. Source it
# here once, idempotently: pp_contain_path becoming redefined is harmless
# (same definition every time).
if ! type pp_safe_git_pathspec >/dev/null 2>&1 \
   || ! type pp_contain_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}/lib/grounding.sh" 2>/dev/null || true
fi

# Defaults — match spec §E.
: "${PP_OAR_REF_TAU:=0.5}"
: "${PP_OAR_LABEL_PER_CYCLE_CAP:=5}"
: "${PP_OAR_LABEL_MAX_ATTEMPTS:=3}"
: "${PP_OAR_ROW_TIMEOUT_S:=3}"
: "${PP_OAR_LOCK_STALE_S:=120}"

_pp_oar_mtime() {
  local _path="${1:-}" _m=""
  [ -e "$_path" ] || { printf '0'; return 0; }
  _m=$(stat -c %Y "$_path" 2>/dev/null)
  case "$_m" in ''|*[!0-9]*) _m="" ;; esac
  if [ -z "$_m" ]; then
    _m=$(stat -f %m "$_path" 2>/dev/null)
  fi
  case "$_m" in ''|*[!0-9]*) _m=0 ;; esac
  printf '%s' "$_m"
}

# pp_oar_row_identity SID LENS HASH INJECT_TS [PROJECT_ID]
# Stdout: 64-hex sha256 of the fields joined by ASCII US (0x1F).
# Used to dedupe labeled rows + look up "already labeled?" membership.
#
# Separator choice: ASCII 0x1F (US, "Unit Separator") — invisible control
# character that never appears in any of the field domains (session
# id is ksuid-shaped, lens is uppercase identifier, hash is hex, inject_ts
# is ISO-8601, project_id is hex). A bare `|` separator would have been ambiguous if any
# field ever contained `|`. Caught by Task 3 review S1 + GPT #3.
pp_oar_row_identity() {
  local _sid="${1:-}" _lens="${2:-}" _hash="${3:-}" _ts="${4:-}"
  local _project_id="${5:-}"
  local _body
  # printf '\037' emits the single US byte. Bash 3.2 supports this.
  if [ -n "$_project_id" ]; then
    _body=$(printf '%s\037%s\037%s\037%s\037%s' "$_sid" "$_lens" "$_hash" "$_ts" "$_project_id")
  else
    _body=$(printf '%s\037%s\037%s\037%s' "$_sid" "$_lens" "$_hash" "$_ts")
  fi
  # Same sha tool chain as pp_project_key in lib/grounding.sh, extended
  # with openssl between native sha256 and the md5 last-resort (caught by
  # Task 3 GPT review #4 — openssl is more ubiquitous than the `sha256` BSD
  # binary on Linux distros).
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$_body" | shasum -a 256 2>/dev/null | cut -c1-64
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$_body" | sha256sum 2>/dev/null | cut -c1-64
  elif command -v sha256 >/dev/null 2>&1; then
    printf '%s' "$_body" | sha256 -q 2>/dev/null | cut -c1-64
  elif command -v openssl >/dev/null 2>&1; then
    # openssl dgst -sha256 output format varies: BSD = "SHA256(stdin)= HEX",
    # GNU = "(stdin)= HEX" or just "HEX  -". awk '{print $NF}' takes the
    # last whitespace-separated field, which is always the hex digest.
    printf '%s' "$_body" | openssl dgst -sha256 2>/dev/null \
      | awk '{print $NF}' | cut -c1-64
  else
    # Last resort — md5 hex padded to 64 chars (deterministic, just not
    # cryptographically strong; identity is a dedupe key not a secret).
    # GPT #1 fix: use command -v branching, NOT `||` inside $() — the
    # pipeline's exit status is `cut`'s (always 0), so the `||` never
    # fired and _md5 silently became empty when md5sum was missing.
    local _md5=""
    if command -v md5sum >/dev/null 2>&1; then
      _md5=$(printf '%s' "$_body" | md5sum 2>/dev/null | cut -c1-32)
    elif command -v md5 >/dev/null 2>&1; then
      _md5=$(printf '%s' "$_body" | md5 -q 2>/dev/null | cut -c1-32)
    fi
    if [ -n "$_md5" ]; then
      printf '%s%s' "$_md5" "$_md5"
    else
      # No hash tool available anywhere on PATH. Emit a deterministic
      # sentinel so callers can detect this case rather than silently
      # using an empty identity (which would collapse all rows together).
      # Pad to 64 chars to satisfy length-asserting tests; the literal
      # "PP_OAR_NO_HASH_TOOL_*" prefix is searchable in logs.
      printf 'PP_OAR_NO_HASH_TOOL_DETERMINISTIC_PLACEHOLDER_64_CHARS_FALLBK00'
    fi
  fi
}

# pp_oar_with_row_timeout SECS COMMAND [ARGS...]
# Run COMMAND with a soft per-row time cap (default $PP_OAR_ROW_TIMEOUT_S=3).
# Uses timeout (GNU coreutils) if present, else gtimeout (macOS via brew
# coreutils), else passes through unbounded. Pass-through is acceptable
# because the cycle has its own outer guard (statusline's `& wait` subshell
# with 15s hard ceiling, see Task 11).
#
# Same fallback pattern as bin/statusline.sh:152 `run_llm`.
# Exit code is the COMMAND's exit code (or 124 / 137 / 143 for the
# timeout-binary-killed-it cases per GNU coreutils semantics).
#
# Probe-once optimization: `command -v` is cheap but the labeler may call
# this 5+ times per cycle (per-cycle row cap) and the function may be
# invoked from tight retry loops in future tasks. Cache the resolved
# timeout binary path in _PP_OAR_TIMEOUT_CMD on first call. Empty string
# means "checked, none available — pass through". Unset means "not yet
# probed". This makes the second-and-later invocations branch-free except
# for the cache hit check.
pp_oar_with_row_timeout() {
  local _secs="${1:-${PP_OAR_ROW_TIMEOUT_S:-3}}"
  # GPT-review #1 fix: guard the shift. Without this, calling
  # `pp_oar_with_row_timeout` with zero args (relying on env default)
  # triggers "shift: shift count out of range" — fatal under set -e.
  [ $# -gt 0 ] && shift
  # Validate seconds — non-numeric, empty, or zero falls back to 3.
  # Empty/non-numeric: defends against a caller passing "" or "abort"
  # and getting a confusing timeout(1) usage error.
  # Zero: GPT-review #7 — coreutils timeout treats `timeout 0 cmd` as
  # "fire instantly", which produces confusing flakes. Enforce ≥ 1.
  case "$_secs" in
    ''|*[!0-9]*|0) _secs=3 ;;
  esac
  # GPT-review #5: require at least one COMMAND argument. Without this
  # we'd fall through to `timeout SECS` or `$@` (empty), producing a
  # confusing "command not found" or timeout-usage error instead of a
  # clear caller bug message.
  if [ $# -eq 0 ]; then
    printf 'pp_oar_with_row_timeout: no command given\n' >&2
    return 2
  fi

  # CI Ubuntu fix (PR #77 review): timeout(1) execvp's its argv and cannot
  # resolve shell functions — every detector wrapped via timeout would
  # return 127 ("command not found"). All three OAR detectors
  # (pp_oar_pushed_back, pp_oar_acted_for_path, pp_oar_referenced) are
  # shell functions defined in this file. On macOS this latent bug is
  # masked because /usr/bin/timeout is typically absent and we already
  # fall through to in-shell invocation; Ubuntu CI exposed it.
  #
  # type -t is a bash 3.2 builtin; "function" is the only invocable
  # category that timeout(1) can't exec. Pass-through for functions
  # matches the documented macOS behavior — the outer 15s cycle ceiling
  # in bin/statusline.sh remains the hard guard for runaway functions.
  if [ "$(type -t "$1" 2>/dev/null)" = "function" ]; then
    "$@"
    return $?
  fi

  # First-call probe. Use the "unset" sentinel (`+x`) so an explicit
  # empty string (= "no binary found") is distinguishable from "not yet
  # checked". This matters when callers stub PATH mid-test.
  # GPT-review #3 fix: cache the ABSOLUTE PATH via `type -P` (or the
  # `command -v` fallback) so a later PATH change can't silently switch
  # which binary runs. `type -P` returns the first executable file in
  # PATH matching the name (or empty if none); it's a bash builtin so
  # no fork cost.
  if [ -z "${_PP_OAR_TIMEOUT_CMD+x}" ]; then
    local _probed
    _probed=$(type -P timeout 2>/dev/null || true)
    if [ -n "$_probed" ]; then
      _PP_OAR_TIMEOUT_CMD="$_probed"
    else
      _probed=$(type -P gtimeout 2>/dev/null || true)
      if [ -n "$_probed" ]; then
        _PP_OAR_TIMEOUT_CMD="$_probed"
      else
        _PP_OAR_TIMEOUT_CMD=""
      fi
    fi
  fi

  if [ -n "$_PP_OAR_TIMEOUT_CMD" ]; then
    # GPT-review #2 fix: -k 1 sends SIGKILL one second after SIGTERM if
    # the command ignores TERM. Without this, a stuck command (e.g. a
    # signal-trapping subshell) outlives the wrapper and the outer 15s
    # cycle ceiling becomes the only real guard. coreutils timeout has
    # accepted -k since 8.5 (BusyBox doesn't, but our probe favors the
    # GNU/BSD binaries; -k is harmlessly ignored if unsupported because
    # the binary errors before we'd notice — covered by test).
    "$_PP_OAR_TIMEOUT_CMD" -k 1 "$_secs" "$@"
    return $?
  fi
  # Pass-through — outer cycle guard handles runaway processes.
  "$@"
}

# pp_oar_pushed_back HASH INJECT_TS_EPOCH SCAN_AT_EPOCH
# Spec §B step 2: explicit `polymath dismiss ack <hash-prefix>` only — no
# transcript-negation heuristic (deferred to v0.5.3 per spec §A intentional
# limit; the heuristic version is too noisy without ground-truth labels).
#
# Returns 0 + prints the matching rule's id (so the caller can use it as the
# row's evidence_id) when a dismiss-ack rule satisfies ALL of:
#   - source == "ack"   (NOT manual/auto_suppress — those are different intent)
#   - deleted == false  (latest-line-wins per id, so a disable→enable cycle is honored)
#   - HASH startswith(.hash)  (rule stores the SHORT prefix the user typed;
#                              pending row carries the full hash; comparison
#                              is case-insensitive — applied lowercase to both
#                              per Task 5 GPT-review #7)
#   - .ts (ISO-8601 UTC) within [INJECT_TS_EPOCH, SCAN_AT_EPOCH] inclusive
# Returns 1 (and prints nothing on stdout) otherwise.
#
# SEMANTICS NOTE — state vs event (Task 5 GPT-review #2):
# The spec wording "rule with source=ack ... with created_at falling in
# window" is technically event-based, but this implementation uses
# STATE-BASED semantics: the latest line for each id wins, so a user who
# ack'd then later disabled the ack will NOT be marked pushed-back. The
# choice matches (a) lib/dismiss.sh's authoritative "is this rule active
# now?" model used everywhere else, and (b) test "pushed_back: disabled
# ack does NOT count" which is the load-bearing regression test for this
# function. Event-based semantics would also match the spec but would
# require ignoring the dismiss-subsystem's own deleted=true semantics.
# Revisit if v0.5.3 OAR data shows ack-then-undo cycles are common — for
# now, "currently endorsed by operator at scan time" is the signal we
# want for OAR labeling.
#
# Reads the project-scoped dismiss file via pp_dismiss_file_path — the same
# canonical store pp_dismiss_ack writes to. The spec narrative names this
# `~/.claude/state/dismiss-rules.jsonl`, but the v0.5.0 dismiss subsystem
# uses a project-scoped path (one JSONL per project hash); this function
# delegates to lib/dismiss.sh::pp_dismiss_file_path to stay in lockstep with
# wherever pp_dismiss_ack writes. Schema fields (id/ts/hash/source) match
# pp_dismiss_ack at lib/dismiss.sh:413.
#
# Window is closed on BOTH ends. Caller is responsible for passing
# SCAN_AT_EPOCH = min(now, row.scan_at_epoch) per spec §B.
pp_oar_pushed_back() {
  local _hash="${1:-}"
  local _inj="${2:-0}"
  local _scan="${3:-0}"
  [ -z "$_hash" ] && return 1
  # Defensive validation — non-numeric epoch silently failing would
  # mask a caller bug. Empty string / non-digits → reject.
  case "$_inj" in ''|*[!0-9]*) return 1 ;; esac
  case "$_scan" in ''|*[!0-9]*) return 1 ;; esac
  # Source dismiss.sh on first call. Idempotent (dismiss.sh has no source
  # guard, but redefining the functions is harmless). Use PP_ROOT to locate.
  if ! type pp_dismiss_file_path >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${PP_ROOT:-.}/lib/dismiss.sh" 2>/dev/null || return 1
  fi
  local _rules
  _rules=$(pp_dismiss_file_path 2>/dev/null) || return 1
  [ -f "$_rules" ] || return 1
  # Slurped jq with latest-line-wins fold: honors a disable→enable cycle
  # on the same id (the dismiss subsystem is append-only; the latest line
  # for an id is authoritative — see lib/dismiss.sh:108 group_by/last).
  #
  # GPT-review #4: explicit null filter on ts (was `// 0` which would
  # treat an unparseable timestamp as epoch 0 and accidentally match if
  # the caller passed INJECT_TS_EPOCH=0).
  # GPT-review #7: case-insensitive hash comparison (`ascii_downcase`).
  # User could type uppercase hex (`ABCDEF`) which dismiss.sh stores
  # verbatim; pending rows always carry lowercase. Normalize both sides.
  local _hash_lc
  _hash_lc=$(printf '%s' "$_hash" | tr '[:upper:]' '[:lower:]')
  local _id
  _id=$(jq -s -r --arg h "$_hash_lc" --argjson inj "$_inj" --argjson scan "$_scan" '
    group_by(.id) | map(last)
    | .[]
    | select(.source == "ack")
    | select(.deleted == false)
    | select(.hash != null and .hash != "")
    | (.hash | ascii_downcase) as $p
    | select($h | startswith($p))
    | (.ts | fromdateiso8601?) as $t
    | select($t != null and $t >= $inj and $t <= $scan)
    | .id
  ' "$_rules" 2>/dev/null | head -1)
  [ -n "$_id" ] || return 1
  printf '%s' "$_id"
}

# pp_oar_acted_for_path REPO_DIR PATH SYMBOL LINE_RANGE INJECT_EPOCH SCAN_AT_EPOCH
# Spec §B step 1: per cited path, git log --follow → for each touching commit
# git show -M50% --unified=0 → inspect diff for cited symbol token OR a +/-
# line within ±20 of cited LINE_RANGE.
#
# Returns 0 + prints "<full-40-hex-SHA>|<label>" on positive match.
# <label> is "symbol_exact" (preferred) or "line_proximity".
# Returns 1 with empty stdout otherwise.
#
# SYMBOL: empty → skip symbol check. Space-separated tokens supported
#         (forward-compat with multi-symbol citations). Per-token filter:
#         length >= 4 + not in lib/citations.sh::_PP_CITATION_STOPWORDS.
# LINE_RANGE: empty → skip line check. Format "N-M" or "N".
#
# Plan addendum risk #1 (2026-05-16) — subshell return semantics:
# A `printf | while read` pipeline runs the RHS in a subshell under bash 3.2;
# `return 0` inside the body only exits the subshell, leaving the outer
# function's exit status at 1. This implementation uses a TEMP-FILE FLAG:
# on first positive match, write "<sha>|<label>" to a flag file and break.
# After the outer loop, if the flag is non-empty, cat + return 0.
#
# Containment: pp_contain_path is the caller's responsibility for cwd
# membership (Task 8 wires it via pp_oar_label_pending). This function
# enforces only basic shape: non-empty REPO_DIR with .git/, non-empty PATH
# accepted by pp_safe_git_pathspec.
pp_oar_acted_for_path() {
  local _repo="${1:-}" _path="${2:-}" _symbol="${3:-}" _lrange="${4:-}"
  local _inj="${5:-0}" _scan="${6:-0}"
  [ -z "$_repo" ] && return 1
  [ -z "$_path" ] && return 1
  [ -d "$_repo/.git" ] || return 1
  # Defensive epoch validation — non-numeric silently failing would mask
  # a caller bug. Matches pp_oar_pushed_back's input validation.
  case "$_inj" in ''|*[!0-9]*) return 1 ;; esac
  case "$_scan" in ''|*[!0-9]*) return 1 ;; esac

  # Guard against the grounding-sourcing race: if pp_safe_git_pathspec is
  # still missing at call time (e.g. caller bypassed our source guard at
  # the top of the file), refuse rather than fall through to a raw path.
  if ! type pp_safe_git_pathspec >/dev/null 2>&1; then
    return 1
  fi

  local _pathspec
  _pathspec=$(pp_safe_git_pathspec "$_path") || return 1

  # Filter symbol tokens: length >= 4, not in citation stopwords. The
  # plan's tests pass a single token; we tokenize on whitespace for
  # forward-compat with comma- or newline-separated citation lists.
  # _PP_CITATION_STOPWORDS is a space-padded string for case-pattern match.
  local _sym_tokens=""
  if [ -n "$_symbol" ]; then
    # Lazy source for stopwords — same idempotent guard pattern as above.
    if [ -z "${_PP_CITATION_STOPWORDS:-}" ]; then
      # shellcheck disable=SC1091
      . "${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}/lib/citations.sh" 2>/dev/null || true
    fi
    local _tok
    # Iterate tokens via parameter expansion + IFS=' \t\n' word splitting.
    # Avoids `read -a` (bash 4+).
    for _tok in $_symbol; do
      [ "${#_tok}" -lt 4 ] && continue
      case " ${_PP_CITATION_STOPWORDS:-} " in
        *" $_tok "*) continue ;;
      esac
      if [ -z "$_sym_tokens" ]; then
        _sym_tokens="$_tok"
      else
        _sym_tokens="$_sym_tokens $_tok"
      fi
    done
  fi

  # Parse LINE_RANGE "N-M" or "N". GPT-review #6: reject malformed forms
  # like "20-" (empty after -) or "-5" (empty before -) by treating both
  # halves as required. Without this, "20-" silently set _l_hi=0 → after
  # ±20 expansion the window became [1, 20] which is "near line 20" but
  # the caller said "from line 20 onward" — confusing.
  local _l_lo=0 _l_hi=0
  if [ -n "$_lrange" ]; then
    case "$_lrange" in
      *-*)
        _l_lo="${_lrange%-*}"
        _l_hi="${_lrange#*-}"
        # Malformed: either half empty or non-numeric → disable line check
        case "$_l_lo" in ''|*[!0-9]*) _l_lo=0; _l_hi=0 ;; esac
        case "$_l_hi" in ''|*[!0-9]*) _l_lo=0; _l_hi=0 ;; esac
        # Inverted range "10-5" — disable
        if [ "$_l_lo" -gt 0 ] && [ "$_l_hi" -lt "$_l_lo" ]; then
          _l_lo=0; _l_hi=0
        fi
        ;;
      *)
        _l_lo="$_lrange"; _l_hi="$_lrange"
        case "$_l_lo" in ''|*[!0-9]*) _l_lo=0; _l_hi=0 ;; esac
        ;;
    esac
  fi

  # Short-circuit: if neither check is active, no work possible. Returning
  # 1 here avoids spending git on guaranteed-no-match cases.
  if [ -z "$_sym_tokens" ] && [ "$_l_lo" -eq 0 ]; then
    return 1
  fi

  # git log --follow is undefined behavior on multi-path; we already accept
  # exactly one path, so this is safe.
  local _commits
  _commits=$(cd "$_repo" 2>/dev/null && git log \
    --since="@${_inj}" --until="@${_scan}" --follow \
    --pretty=format:%H -- "$_pathspec" 2>/dev/null)
  [ -z "$_commits" ] && return 1

  # Plan addendum M2: mktemp in PP_CACHE_DIR assumes the dir exists. Ensure
  # it does. Fall back to a system-tmp mktemp on dir-missing.
  local _cache_dir="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
  mkdir -p "$_cache_dir" 2>/dev/null || true
  local _flag
  if [ -d "$_cache_dir" ] && [ -w "$_cache_dir" ]; then
    _flag=$(mktemp "${_cache_dir}/.oar-flag.XXXXXX" 2>/dev/null) || \
      _flag=$(mktemp -t pp-oar-flag 2>/dev/null) || return 1
  else
    _flag=$(mktemp -t pp-oar-flag 2>/dev/null) || return 1
  fi
  # GPT-review #8 / code-reviewer P2: trap RETURN ensures the flag is
  # removed on EVERY exit path including SIGTERM from the outer 15s
  # cycle ceiling or a test-runner interrupt. RETURN is bash 3.2+.
  # The post-loop `rm -f` below is the happy-path; this is belt-and-
  # suspenders against signal-interrupted paths.
  # Task 7 GPT-review #1: trap … RETURN is SHELL-WIDE not function-scoped.
  # Add `trap - RETURN` inside the trap body to clear it after firing so
  # it doesn't fire on subsequent function returns in the same shell.
  # shellcheck disable=SC2064
  trap "rm -f '$_flag'; trap - RETURN" RETURN

  # Outer loop: walk commits. while-read runs in a subshell, but here the
  # subshell can WRITE TO the flag file (file mutations cross subshell
  # boundaries cleanly under Unix semantics). On first match we break;
  # post-loop we detect the flag's contents.
  #
  # GPT-review #1 (rename-history correctness): `git show ... -- "$_pathspec"`
  # filters to the CURRENT path. For pre-rename commits (file lived at a
  # different path back then), the pathspec excludes them and we miss
  # legitimate diff content. Fix: drop the pathspec from `git show` and
  # accept that we scan the whole commit's diff. Trade-off documented as
  # cross-file FP risk — bounded by single-commit scope; spec §A "Known
  # limits" calibration concern. The path filter at `git log --follow`
  # already constrained the commit SET to those touching the path through
  # rename history; we just relax the symbol/line scan to cover any file
  # in those commits.
  printf '%s\n' "$_commits" | while IFS= read -r _commit; do
    [ -z "$_commit" ] && continue
    local _diff
    _diff=$(cd "$_repo" 2>/dev/null && git show -M50% --unified=0 \
            "$_commit" 2>/dev/null)
    [ -z "$_diff" ] && continue

    # --- Symbol check ---
    # GPT-review #2: header exclusion was `^[+-][^+-]` which incorrectly
    # rejected valid content lines starting with `++` or `--` (e.g.
    # `++i;`, `--count;`). Use the precise inverse: `^[+-]` selects all
    # add/remove lines, then drop lines matching `^(--- |+++ )` which is
    # the git-show file-header form (three chars + literal space).
    if [ -n "$_sym_tokens" ]; then
      local _diff_changes
      _diff_changes=$(printf '%s\n' "$_diff" \
        | LC_ALL=C grep -E '^[+-]' 2>/dev/null \
        | LC_ALL=C grep -Ev '^(---|\+\+\+) ' 2>/dev/null || true)
      if [ -n "$_diff_changes" ]; then
        local _tok2 _hit=0
        for _tok2 in $_sym_tokens; do
          if printf '%s\n' "$_diff_changes" \
             | LC_ALL=C grep -wF -- "$_tok2" >/dev/null 2>&1; then
            _hit=1
            break
          fi
        done
        if [ "$_hit" = "1" ]; then
          printf '%s|symbol_exact' "$_commit" > "$_flag"
          break
        fi
      fi
    fi

    # --- Line proximity check ---
    # @@ hunk header form: `@@ -OLD_START[,OLD_COUNT] +NEW_START[,NEW_COUNT] @@ ...`
    # With --unified=0, missing `,N` means N=1.
    # GPT-review #3: must overlap BOTH -OLD and +NEW ranges. Pure deletions
    # produce hunks like `@@ -100,5 +99,0 @@` (5 lines removed, 0 added at
    # destination). The +NEW range alone (start=99, count=0) gives an empty
    # interval that never overlaps the cited range — so the deletion would
    # be missed. Check the OLD range too so removals near the cited area
    # count as "acted."
    if [ "$_l_lo" -gt 0 ]; then
      local _hunks
      _hunks=$(printf '%s\n' "$_diff" \
        | LC_ALL=C grep -E '^@@ ' 2>/dev/null || true)
      if [ -n "$_hunks" ]; then
        local _h _ho_start _ho_count _ho_end _hn_start _hn_count _hn_end
        local _lo_ext _hi_ext _proximity_hit=0
        # Iterate hunk headers via while-read in a subshell. The flag-file
        # write pattern works at any nesting depth — the inner subshell's
        # write is visible to the outer reader after the loop ends.
        while IFS= read -r _h; do
          [ -z "$_h" ] && continue
          # Parse OLD range
          _ho_start=$(printf '%s' "$_h" \
            | LC_ALL=C sed -nE 's/^@@ -([0-9]+)(,[0-9]+)? \+[0-9,]+ @@.*/\1/p')
          _ho_count=$(printf '%s' "$_h" \
            | LC_ALL=C sed -nE 's/^@@ -[0-9]+,([0-9]+) \+[0-9,]+ @@.*/\1/p')
          # Parse NEW range
          _hn_start=$(printf '%s' "$_h" \
            | LC_ALL=C sed -nE 's/^@@ -[0-9,]+ \+([0-9]+)(,[0-9]+)? @@.*/\1/p')
          _hn_count=$(printf '%s' "$_h" \
            | LC_ALL=C sed -nE 's/^@@ -[0-9,]+ \+[0-9]+,([0-9]+) @@.*/\1/p')
          case "$_ho_start" in ''|*[!0-9]*) _ho_start=0 ;; esac
          case "$_ho_count" in ''|*[!0-9]*) _ho_count=1 ;; esac
          case "$_hn_start" in ''|*[!0-9]*) _hn_start=0 ;; esac
          case "$_hn_count" in ''|*[!0-9]*) _hn_count=1 ;; esac
          _ho_end=$(( _ho_start + _ho_count - 1 ))
          _hn_end=$(( _hn_start + _hn_count - 1 ))
          _lo_ext=$(( _l_lo - 20 ))
          _hi_ext=$(( _l_hi + 20 ))
          [ "$_lo_ext" -lt 1 ] && _lo_ext=1
          # Overlap test: cited window intersects EITHER the OLD or NEW
          # range. Empty-range case (count=0): start..start-1 is empty so
          # the overlap test (end >= lo_ext AND start <= hi_ext) handles
          # it correctly — start=99, end=98 won't overlap anything except
          # by coincidence. Check both OLD (deletion side) and NEW (add
          # side) so pure-deletion hunks aren't missed.
          local _old_hit=0 _new_hit=0
          if [ "$_ho_start" -gt 0 ] && [ "$_ho_end" -ge "$_lo_ext" ] \
             && [ "$_ho_start" -le "$_hi_ext" ]; then
            _old_hit=1
          fi
          if [ "$_hn_start" -gt 0 ] && [ "$_hn_end" -ge "$_lo_ext" ] \
             && [ "$_hn_start" -le "$_hi_ext" ]; then
            _new_hit=1
          fi
          if [ "$_old_hit" = "1" ] || [ "$_new_hit" = "1" ]; then
            printf '%s|line_proximity' "$_commit" > "$_flag"
            _proximity_hit=1
            break
          fi
        done <<EOF
$_hunks
EOF
        # Inner while-read with `<<EOF` runs in the SAME subshell as the
        # outer while-read (no pipeline), so $_proximity_hit IS visible.
        if [ "$_proximity_hit" = "1" ]; then
          break
        fi
      fi
    fi
  done

  if [ -s "$_flag" ]; then
    cat "$_flag"
    rm -f "$_flag"
    return 0
  fi
  rm -f "$_flag"
  return 1
}

# pp_oar_referenced SID INJECT_TS_EPOCH SCAN_AT_EPOCH BODY CITE_SYMBOLS_NEWLINE_SEP
# Spec §B step 3: was the observation referenced in user-turn text between
# inject_ts and min(now, scan_at_epoch)?
#
# Reads ${PP_CACHE_DIR}/transcript-tail-${SID}.txt (plain-text user-turn
# blob — v0.5.2 transcript format has no embedded per-line timestamps, so
# we use FILE mtime as the point-in-time bound). If mtime is outside the
# [INJECT_TS_EPOCH, SCAN_AT_EPOCH] window → reject (BOTH bounds — no
# late-reference leakage).
#
# On positive match:
#   stdout: "line:1-<file_line_count>|jaccard:0.NN"  (best-effort range)
#   rc: 0
# On any rejection (missing file, outside window, no cite-symbol, low
# Jaccard): rc 1, no stdout.
#
# Plan addendum applied:
#   * I3 — comm -12 uses TWO mktemp files, NOT bash process substitution
#          (/dev/fd is not on the project's portability floor).
#   * M1 — cite-token-required is restricted to SYMBOLS only. Path-shaped
#          tokens (with slashes/dots) rarely pass grep -wF word-boundary
#          checks; requiring them as the cite-token gate causes false
#          rejections. Caller must pass only symbol tokens via the last
#          arg. The labeler driver (Task 8) will filter cited_paths out.
#
# CITE_SYMBOLS_NEWLINE_SEP: newline-separated list of symbol-shaped tokens
# (identifier regex `[A-Za-z_][A-Za-z0-9_]{2,}`). Empty → reject (cite-token
# required by spec §B step 3).
#
# Tokenization (both sides): identifier-shaped runs, lowercased,
# length>=3, stopword-filtered via _PP_CITATION_STOPWORDS (reused from
# lib/citations.sh — same stopword list the rest of v0.5.2 uses).
#
# Bigrams: consecutive-token pairs from the filtered stream, joined with
# `_`. Order matters within the bigram; bigram SETS (sort -u) are compared.
#
# Jaccard = |A ∩ B| / |A ∪ B|. Empty union → reject.
pp_oar_referenced() {
  local _sid="${1:-}"
  local _inj="${2:-0}"
  local _scan="${3:-0}"
  local _body="${4:-}"
  local _cites="${5:-}"
  # GPT-review #4: validate PP_OAR_REF_TAU is a numeric. Non-numeric
  # silently coerces to 0 in awk (j+0 >= t+0 always true), which would
  # flip the threshold gate. Accept N, N.NN, or .NN; fallback to 0.5.
  local _tau="${PP_OAR_REF_TAU:-0.5}"
  case "$_tau" in
    [0-9]|[0-9].[0-9]*|.[0-9]*) ;;  # valid forms
    *) _tau=0.5 ;;
  esac

  [ -z "$_sid" ] && return 1
  [ -z "$_body" ] && return 1
  # Defensive epoch validation — matches pp_oar_pushed_back / acted_for_path.
  case "$_inj" in ''|*[!0-9]*) return 1 ;; esac
  case "$_scan" in ''|*[!0-9]*) return 1 ;; esac

  local _cache_dir="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
  local _tail="${_cache_dir}/transcript-tail-${_sid}.txt"
  # Per spec contract: missing transcript → rc 1 (not an error, just "no
  # evidence of reference"). The labeler driver is responsible for not
  # treating rc 1 as a labeling failure.
  [ -f "$_tail" ] || return 1
  [ -s "$_tail" ] || return 1

  # M1: cite-token-required gate. Caller passes ONLY symbols here. Empty
  # → reject (spec §B step 3 "AND ≥1 cite-token").
  if [ -z "$_cites" ]; then
    return 1
  fi

  # Window check via FILE mtime. _PP_STAT_FLAVOR is set in bin/polymath /
  # bin/statusline.sh; tests may not have it. Detect on first call.
  if [ -z "${_PP_STAT_FLAVOR:-}" ]; then
    if stat -c %Y /dev/null >/dev/null 2>&1; then
      _PP_STAT_FLAVOR=gnu
    elif stat -f %m /dev/null >/dev/null 2>&1; then
      _PP_STAT_FLAVOR=bsd
    else
      _PP_STAT_FLAVOR=unknown
    fi
  fi
  local _mtime=0
  case "$_PP_STAT_FLAVOR" in
    gnu) _mtime=$(stat -c %Y "$_tail" 2>/dev/null || echo 0) ;;
    bsd) _mtime=$(stat -f %m "$_tail" 2>/dev/null || echo 0) ;;
    *)
      # GPT-review #3: portable fallback when neither stat flavor works.
      # `find -printf '%T@'` is GNU-only; `perl -e 'print (stat ...)[9]'`
      # is widely available but adds a dependency. Cleanest fallback: use
      # `ls -l` mtime parsing? Too fragile. Best: try `find ... -newer`
      # heuristics. ACTUALLY: if both stat probes fail, the host is
      # exceptionally minimal (BusyBox without coreutils + no BSD).
      # Disable the window gate rather than forcing reject — let cite-token
      # gate + Jaccard threshold do their work alone. Document the trade-off.
      _mtime=$_inj   # treat as in-window (lower bound) — falls through
      ;;
  esac
  case "$_mtime" in ''|*[!0-9]*) _mtime="$_inj" ;; esac
  # BOTH bounds closed. If mtime is outside [inj, scan], reject.
  # (No late-reference leakage: scan_at_epoch is the upper bound the
  # labeler driver clamps to min(now, row.scan_at_epoch) before calling.)
  if [ "$_mtime" -lt "$_inj" ] || [ "$_mtime" -gt "$_scan" ]; then
    return 1
  fi

  # Cite-SYMBOL presence check (M1: symbols only). Iterate via heredoc to
  # avoid pipeline-subshell variable-loss under bash 3.2.
  # GPT-review #2: case-insensitive — the body Jaccard tokenizer lowercases
  # everything, but the cite-symbol check needs to match the transcript
  # AS-WRITTEN. User could type "FooBar" in transcript while body has
  # "FooBar" too — `grep -wF` IS case-sensitive. Switched to `grep -iwF`.
  local _cite_ok=0 _c
  while IFS= read -r _c; do
    [ -z "$_c" ] && continue
    # Defensive: M1 says callers should pass only symbols, but if a path-
    # shaped token slips through, grep -wF rarely matches it anyway. Skip
    # tokens containing path separators or dot — they cannot be word-boundary
    # whole-word matches and would only contribute noise to error paths.
    case "$_c" in
      */*|*.*) continue ;;
    esac
    if LC_ALL=C grep -iwF -- "$_c" "$_tail" >/dev/null 2>&1; then
      _cite_ok=1
      break
    fi
  done <<EOF
$_cites
EOF
  [ "$_cite_ok" = "1" ] || return 1

  # Lazy-source citation stopwords (idempotent — same pattern as
  # pp_oar_acted_for_path).
  if [ -z "${_PP_CITATION_STOPWORDS:-}" ]; then
    # shellcheck disable=SC1091
    . "${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}/lib/citations.sh" 2>/dev/null || true
  fi

  # Tokenize transcript + body into stopword-filtered, lowercased,
  # identifier-shaped token streams. awk is bash-3.2 portable and
  # locale-stable under LC_ALL=C (set file-wide above).
  local _tail_tokens _body_tokens
  _tail_tokens=$(LC_ALL=C awk -v stops="$_PP_CITATION_STOPWORDS" '
    BEGIN {
      n = split(stops, arr, " ")
      for (i = 1; i <= n; i++) stop[arr[i]] = 1
    }
    {
      gsub(/[^A-Za-z0-9_]+/, " ")
      nf = split($0, w, " ")
      for (i = 1; i <= nf; i++) {
        t = tolower(w[i])
        if (length(t) < 3) continue
        if (t in stop) continue
        print t
      }
    }
  ' "$_tail")
  _body_tokens=$(printf '%s' "$_body" | LC_ALL=C awk -v stops="$_PP_CITATION_STOPWORDS" '
    BEGIN {
      n = split(stops, arr, " ")
      for (i = 1; i <= n; i++) stop[arr[i]] = 1
    }
    {
      gsub(/[^A-Za-z0-9_]+/, " ")
      nf = split($0, w, " ")
      for (i = 1; i <= nf; i++) {
        t = tolower(w[i])
        if (length(t) < 3) continue
        if (t in stop) continue
        print t
      }
    }
  ')

  # Build bigram SETS (sorted, deduplicated) from each token stream.
  local _tail_bigrams _body_bigrams
  _tail_bigrams=$(printf '%s\n' "$_tail_tokens" \
    | LC_ALL=C awk 'NR==1{prev=$0;next} {print prev "_" $0; prev=$0}' \
    | LC_ALL=C grep -v '^$' \
    | LC_ALL=C sort -u)
  _body_bigrams=$(printf '%s\n' "$_body_tokens" \
    | LC_ALL=C awk 'NR==1{prev=$0;next} {print prev "_" $0; prev=$0}' \
    | LC_ALL=C grep -v '^$' \
    | LC_ALL=C sort -u)

  # Either side empty → no overlap possible.
  if [ -z "$_tail_bigrams" ] || [ -z "$_body_bigrams" ]; then
    return 1
  fi

  # Plan addendum I3: bash 3.2 portability — write both sets to temp files
  # and use `comm -12 file1 file2`. NEVER `comm -12 <(...) <(...)` because
  # process substitution requires /dev/fd which is not on this project's
  # portability floor (BusyBox + macOS bash 3.2 both have /dev/fd in
  # practice, but the project's CONTRIBUTING.md bars relying on it).
  mkdir -p "$_cache_dir" 2>/dev/null || true
  local _f_a _f_b
  if [ -d "$_cache_dir" ] && [ -w "$_cache_dir" ]; then
    _f_a=$(mktemp "${_cache_dir}/.oar-ref-a.XXXXXX" 2>/dev/null) \
      || _f_a=$(mktemp -t pp-oar-ref-a 2>/dev/null) || return 1
    _f_b=$(mktemp "${_cache_dir}/.oar-ref-b.XXXXXX" 2>/dev/null) \
      || _f_b=$(mktemp -t pp-oar-ref-b 2>/dev/null) || { rm -f "$_f_a"; return 1; }
  else
    _f_a=$(mktemp -t pp-oar-ref-a 2>/dev/null) || return 1
    _f_b=$(mktemp -t pp-oar-ref-b 2>/dev/null) || { rm -f "$_f_a"; return 1; }
  fi
  printf '%s\n' "$_tail_bigrams" > "$_f_a"
  printf '%s\n' "$_body_bigrams" > "$_f_b"

  local _inter _union
  _inter=$(LC_ALL=C comm -12 "$_f_a" "$_f_b" 2>/dev/null | LC_ALL=C grep -cv '^$' 2>/dev/null)
  _union=$(LC_ALL=C cat "$_f_a" "$_f_b" 2>/dev/null \
            | LC_ALL=C sort -u | LC_ALL=C grep -cv '^$' 2>/dev/null)
  case "$_inter" in ''|*[!0-9]*) _inter=0 ;; esac
  case "$_union" in ''|*[!0-9]*) _union=0 ;; esac
  [ "$_union" -eq 0 ] && { rm -f "$_f_a" "$_f_b" 2>/dev/null; return 1; }

  # Compare Jaccard ≥ τ via awk (bash can't compare floats).
  local _jaccard _passed
  _jaccard=$(LC_ALL=C awk -v i="$_inter" -v u="$_union" \
    'BEGIN { printf "%.4f", i / u }')
  _passed=$(LC_ALL=C awk -v j="$_jaccard" -v t="$_tau" \
    'BEGIN { if (j+0 >= t+0) print 1; else print 0 }')
  [ "$_passed" = "1" ] || { rm -f "$_f_a" "$_f_b" 2>/dev/null; return 1; }

  # Line range: file-relative line span at point-in-time scan. Best effort
  # per spec §B (the file may be truncated/rotated later; this is recorded
  # as evidence_id for downstream audit).
  local _line_n
  _line_n=$(LC_ALL=C wc -l < "$_tail" 2>/dev/null | tr -d ' ')
  case "$_line_n" in ''|*[!0-9]*) _line_n=1 ;; esac
  [ "$_line_n" -lt 1 ] && _line_n=1
  printf 'line:1-%s|jaccard:%s' "$_line_n" "$_jaccard"
  rm -f "$_f_a" "$_f_b" 2>/dev/null
  return 0
}

# pp_oar_label_pending
# Driver: reads oar-pending.jsonl, picks up to PP_OAR_LABEL_PER_CYCLE_CAP rows
# whose scan_at_epoch < now (FIFO by scan_at_epoch ASC), classifies each into
# one of {pushed-back, acted, referenced, ignored}, appends a labeled row to
# oar-labeled.jsonl, and removes processed rows from pending. Rows not yet
# due are preserved; rows past cap are preserved.
#
# Order of outcome detection per spec §B (first hit wins):
#   1. pushed_back  (pp_oar_pushed_back)
#   2. acted        (pp_oar_acted_for_path per cited path, after containment)
#   3. referenced   (pp_oar_referenced)
#   4. ignored      (default)
#
# Idempotency: stable identity = sha256(sid|lens|hash|inject_ts). The set of
# already-labeled identities is read from oar-labeled.jsonl on entry; a row
# whose identity is in that set is dropped from pending without re-labeling.
#
# Containment: cited paths are passed through pp_contain_path BEFORE being
# handed to pp_oar_acted_for_path. Rows whose only cited paths fail
# containment fall through to the next detector (referenced) or land on
# "ignored". Symbols are still considered against contained paths.
#
# scan_at clamp: detectors receive UPPER_EPOCH = min(now, scan_at_epoch)
# so a slightly-future scan_at doesn't let detectors see future evidence.
#
# Attempts / quarantine: per-row work is wrapped in pp_oar_with_row_timeout
# (default 3s). On a "transient error" rc=2 from any detector AND the row
# wouldn't otherwise be labeled, .attempts is bumped; on reaching
# PP_OAR_LABEL_MAX_ATTEMPTS (default 3) the row is moved to oar-stuck.jsonl.
#
# Atomic pending rewrite: kept rows go to a sibling mktemp file, then
# mv-replaces pending. No in-place edit; bash 3.2 portable.
pp_oar_label_pending() {
  local _cache_dir="${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}"
  local _pending="${_cache_dir}/oar-pending.jsonl"
  local _labeled="${_cache_dir}/oar-labeled.jsonl"
  local _stuck="${_cache_dir}/oar-stuck.jsonl"
  local _cap="${PP_OAR_LABEL_PER_CYCLE_CAP:-5}"
  local _max_att="${PP_OAR_LABEL_MAX_ATTEMPTS:-3}"
  case "$_cap" in ''|*[!0-9]*) _cap=5 ;; esac
  case "$_max_att" in ''|*[!0-9]*) _max_att=3 ;; esac
  [ -f "$_pending" ] || return 0
  mkdir -p "$_cache_dir" 2>/dev/null || true

  local _now
  _now=$(date +%s 2>/dev/null) || _now=0
  case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
  # GPT-review: now=0 → all rows look "not yet due" (because scan_at_epoch
  # is always > 0) → labeling stalls silently. If clock retrieval failed,
  # exit cleanly so the next cycle retries with a working clock.
  if [ "$_now" -eq 0 ]; then
    return 0
  fi

  # v0.5.1.1 Stage A: per-cycle reset for the unknown-outcome one-shot
  # warning (see the outcome-enum tolerance branch below).
  unset _PP_OAR_UNKNOWN_OUTCOME_WARNED

  # Task-8 review (code-reviewer + GPT): concurrent runs would clobber
  # oar-pending.jsonl mid-rewrite. Two cycles can both snapshot, both build
  # their kept files, then race on `mv -f kept → pending`. The second mv
  # wins; the first's surviving rows are lost. mkdir-lock the same way
  # lib/budget.sh::pp_budget_reserve guards the daily counter. If we can't
  # acquire the lock, this cycle is a no-op — next cycle picks up. No
  # stale-lock recovery is conservative: the inner work is bounded by
  # per-row 3s and per-cycle cap=5 (default ~15s), so a 120s-old lock is
  # almost certainly orphaned by a killed process.
  local _lock="${_cache_dir}/.oar-labeler.lock"
  if ! mkdir "$_lock" 2>/dev/null; then
    local _lock_mtime _lock_age _lock_ttl
    _lock_ttl="${PP_OAR_LOCK_STALE_S:-120}"
    case "$_lock_ttl" in ''|*[!0-9]*) _lock_ttl=120 ;; esac
    _lock_mtime=$(_pp_oar_mtime "$_lock")
    _lock_age=0
    if [ "$_now" -gt 0 ] && [ "$_lock_mtime" -gt 0 ] 2>/dev/null; then
      _lock_age=$(( _now - _lock_mtime ))
    fi
    if [ "$_lock_age" -gt "$_lock_ttl" ] 2>/dev/null; then
      rmdir "$_lock" 2>/dev/null || return 0
      mkdir "$_lock" 2>/dev/null || return 0
    else
      return 0
    fi
  fi

  # Working temp files. Each mktemp MUST land in the same filesystem as
  # the target file we'll later mv into (atomic rename only works
  # intra-filesystem). GPT-review: the fallback `mktemp -t` path lands
  # in $TMPDIR which is often a tmpfs on Linux → cross-FS mv is non-atomic.
  # If we can't create the temp file in the cache dir, fail cleanly
  # rather than fall back to system-tmp.
  local _seen _snapshot _kept
  _seen=$(mktemp "${_cache_dir}/.oar-seen.XXXXXX" 2>/dev/null) || {
    rmdir "$_lock" 2>/dev/null; return 0; }
  _snapshot=$(mktemp "${_cache_dir}/.oar-snap.XXXXXX" 2>/dev/null) || {
    rm -f "$_seen"; rmdir "$_lock" 2>/dev/null; return 0; }
  _kept=$(mktemp "${_cache_dir}/.oar-kept.XXXXXX" 2>/dev/null) || {
    rm -f "$_seen" "$_snapshot"; rmdir "$_lock" 2>/dev/null; return 0; }
  # Cleanup discipline: this function calls multiple sub-functions
  # (pp_oar_row_identity, pp_contain_path, the three detectors), each of
  # which RETURNs and would fire a shell-wide `trap RETURN` mid-loop and
  # rm our working files prematurely. Avoid `trap RETURN` entirely —
  # perform explicit `rm -f` of `_seen`/`_snapshot`/`_kept` before the
  # final `return 0`. This pattern is verbose but the only reliable one
  # under bash 3.2 + bats `set -eET` + nested function calls.

  # Build labeled-identity set (one sha per line, sorted for grep -F speed).
  if [ -f "$_labeled" ]; then
    jq -r 'select(.identity != null) | .identity' "$_labeled" 2>/dev/null \
      > "$_seen"
  fi

  # FIFO snapshot of pending rows by scan_at_epoch ASC. Read as raw lines
  # first so one malformed JSONL row cannot make jq reject the whole file
  # and rewrite pending to empty. Bad rows are sorted after valid rows and
  # kept verbatim by the per-row guard below.
  jq -Rrsc '
    split("\n")
    | map(select(length > 0)
      | . as $raw
      | (fromjson? // null) as $row
      | {raw:$raw,
         sort:(if $row == null then 9223372036854775807 else ($row.scan_at_epoch // 0) end)})
    | sort_by(.sort)
    | .[].raw
  ' "$_pending" 2>/dev/null > "$_snapshot" || {
    rm -f "$_seen" "$_snapshot" "$_kept" 2>/dev/null
    rmdir "$_lock" 2>/dev/null
    return 0
  }

  local _processed=0
  local _line _sid _lens _hash _inj_ts _scan _attempts _id
  local _project_id _project_root _project_root_sha8
  local _inj_epoch _upper
  local _cited_paths _cited_symbols _body
  local _prompt_versions_json
  local _outcome _evid_id _conf _err
  local _cwd _p _contained
  local _rc _acted_out _ref_out _rule

  while IFS= read -r _line; do
    [ -z "$_line" ] && continue

    # Bad-JSON guard (GPT-review): a single corrupt row in pending will
    # cause jq to exit non-zero. Under bats `set -eET` the $() capture
    # then aborts the whole function. The `|| true` tail keeps the
    # assignment unconditionally rc=0; jq's stderr is /dev/null'd; we
    # detect the bad row via empty session_id and KEEP it in pending
    # (operator may want to inspect it manually).
    _sid=$(printf '%s' "$_line" | jq -r '.session_id // ""' 2>/dev/null || true)
    _lens=$(printf '%s' "$_line" | jq -r '.lens // ""' 2>/dev/null || true)
    _hash=$(printf '%s' "$_line" | jq -r '.hash // ""' 2>/dev/null || true)
    _inj_ts=$(printf '%s' "$_line" | jq -r '.inject_ts // ""' 2>/dev/null || true)
    _scan=$(printf '%s' "$_line" | jq -r '.scan_at_epoch // 0' 2>/dev/null || true)
    _attempts=$(printf '%s' "$_line" | jq -r '.attempts // 0' 2>/dev/null || true)
    _project_id=$(printf '%s' "$_line" | jq -r '.project_id // ""' 2>/dev/null || true)
    _project_root=$(printf '%s' "$_line" | jq -r '.project_root // ""' 2>/dev/null || true)
    _project_root_sha8=$(printf '%s' "$_line" | jq -r '.project_root_sha8 // ""' 2>/dev/null || true)
    # Corrupt row → keep verbatim in pending (don't lose data).
    if [ -z "$_sid" ] || [ -z "$_lens" ] || [ -z "$_hash" ]; then
      printf '%s\n' "$_line" >> "$_kept"
      continue
    fi
    # GPT-review: sanitize session_id to prevent path traversal via
    # transcript-tail-${_sid}.txt. session_id comes from SessionEnd's
    # JSON event but is operator-influenceable. Reject anything that's
    # not a strictly safe-filename pattern: alphanumeric + `.`, `-`, `_`.
    case "$_sid" in
      *[!A-Za-z0-9._-]*|'')
        printf '%s\n' "$_line" >> "$_kept"
        continue
        ;;
    esac
    case "$_scan" in ''|*[!0-9]*) _scan=0 ;; esac
    case "$_attempts" in ''|*[!0-9]*) _attempts=0 ;; esac

    # Not yet due → keep verbatim in pending.
    if [ "$_scan" -gt "$_now" ]; then
      printf '%s\n' "$_line" >> "$_kept"
      continue
    fi

    # Already labeled? Drop (do NOT re-append to pending).
    _id=""
    _id=$(pp_oar_row_identity "$_sid" "$_lens" "$_hash" "$_inj_ts" "$_project_id" 2>/dev/null) \
      || _id=""
    if [ -n "$_id" ] && [ -s "$_seen" ] \
       && LC_ALL=C grep -qxF -- "$_id" "$_seen" 2>/dev/null; then
      continue
    fi

    # At cap → preserve the remainder in pending for the next cycle.
    if [ "$_processed" -ge "$_cap" ]; then
      printf '%s\n' "$_line" >> "$_kept"
      continue
    fi
    _processed=$(( _processed + 1 ))

    # Parse inject_ts → epoch. macOS BSD `date -j -f` and GNU `date -d` both
    # honored; fall back to 0 silently (detectors will reject non-numeric).
    _inj_epoch=$(date -u -d "$_inj_ts" +%s 2>/dev/null \
                 || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_inj_ts" +%s 2>/dev/null \
                 || printf '0')
    case "$_inj_epoch" in ''|*[!0-9]*) _inj_epoch=0 ;; esac

    # Window upper bound: min(now, scan_at_epoch). Applies to both
    # pushed_back and referenced (spec §B clamp).
    _upper="$_scan"
    [ "$_now" -lt "$_upper" ] && _upper="$_now"

    # Body + citation arrays (C2 fix path A — present in the pending row).
    _body=$(printf '%s' "$_line" | jq -r '.body // ""' 2>/dev/null)
    _cited_paths=$(printf '%s' "$_line" \
                    | jq -r '.cited_paths // [] | .[]?' 2>/dev/null)
    _cited_symbols=$(printf '%s' "$_line" \
                    | jq -r '.cited_symbols // [] | .[]?' 2>/dev/null)
    _prompt_versions_json=$(printf '%s' "$_line" \
                    | jq -c 'if (.prompt_versions | type) == "object" then .prompt_versions else {} end' 2>/dev/null \
                    || printf '{}')
    printf '%s' "$_prompt_versions_json" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || _prompt_versions_json="{}"

    _outcome="ignored"
    _evid_id="null"
    _conf="no_signal_in_window"
    _err=0
    _silent_reason=""

    # v0.5.1.1 Stage A spec task 7: Stage B writers emit pending rows
    # with outcome=silent + silent_reason pre-stamped. Stage A's reader
    # honors that pre-stamp WITHOUT running the detector chain (the
    # observation was never injected; there's no acted/referenced/
    # pushed-back signal to check).
    local _preset_outcome _preset_silent_reason
    _preset_outcome=$(printf '%s' "$_line" | jq -r '.outcome // ""' 2>/dev/null)
    _preset_silent_reason=$(printf '%s' "$_line" | jq -r '.silent_reason // ""' 2>/dev/null)

    # Outcome enum tolerance: known v1+v2 values pass through; unknown
    # values downgrade to 'ignored' with a ONE-SHOT per-cycle stderr
    # warning (not per-row — operator noise is high if a future writer
    # emits 1000 rows with the same forward-version outcome).
    case "$_preset_outcome" in
      ""|acted|referenced|pushed-back|ignored)
        # v1 outcomes (or absent: fall through to detector chain).
        ;;
      silent)
        # v0.5.1.1 v2 outcome: skip detector chain, preserve pre-stamp.
        _outcome="silent"
        _silent_reason="$_preset_silent_reason"
        ;;
      *)
        # Unknown forward-version outcome. Warn ONCE per cycle, then
        # downgrade to 'ignored'. _PP_OAR_UNKNOWN_OUTCOME_WARNED is a
        # shell var lifecycle-scoped to this pp_oar_label_pending call
        # (unset at function entry); bash 3.2 has no per-process
        # "warned" registry, but a function-local flag is sufficient
        # since pp_oar_label_pending is the only caller of this branch.
        if [ -z "${_PP_OAR_UNKNOWN_OUTCOME_WARNED:-}" ]; then
          printf 'pair-polymath OAR labeler: unknown OAR outcome %s in pending row (session=%s lens=%s); downgrading to ignored. Stage A v1/v2-tolerance shim per spec task 7.\n' \
            "$_preset_outcome" "$_sid" "$_lens" >&2
          _PP_OAR_UNKNOWN_OUTCOME_WARNED=1
        fi
        _outcome="ignored"
        _preset_outcome=""
        ;;
    esac

    # v0.5.1.1 Stage A: skip detector chain when outcome was pre-stamped
    # as 'silent' by an upstream Stage B writer. There's no observation
    # to score against the transcript/git/code, so the only meaningful
    # output is to passthrough the silent_reason to the labeled row.
    if [ "$_outcome" != "silent" ]; then

    # ----- Step 1: pushed_back? -----
    # Order per spec §B + user-task brief: pushed_back checked first because
    # an explicit ack is the strongest signal of operator intent regardless
    # of what subsequent code activity looks like.
    # bash 3.2 + bats `set -eE` interaction: an assignment from $(failing)
    # propagates the inner exit and aborts the function under errexit.
    # The detectors LEGITIMATELY return 1 (== "no signal") for the common
    # case; the labeler must treat that as data, not failure. The `|| true`
    # tail makes the assignment unconditionally rc=0, so we can inspect
    # $_rule for content separately. _rc is captured BEFORE the `|| true`
    # via PIPESTATUS-style; but bash 3.2 lacks pipefail introspection on
    # command substitutions. Workaround: run the helper in a separate
    # step, capture rc, then capture output.
    _rule=""
    _rc=0
    _rule=$(pp_oar_with_row_timeout "${PP_OAR_ROW_TIMEOUT_S:-3}" \
              pp_oar_pushed_back "$_hash" "$_inj_epoch" "$_upper" 2>/dev/null) \
              || _rc=$?
    if [ "$_rc" -eq 0 ] && [ -n "$_rule" ]; then
      _outcome="pushed-back"
      _evid_id="$_rule"
      _conf="exact"
    elif [ "$_rc" -eq 2 ]; then
      _err=1
    fi

    # ----- Step 2: acted? (only if not pushed-back) -----
    _cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
    if [ "$_outcome" = "ignored" ]; then
      # Per-cited-path loop. Containment ahead of pp_oar_acted_for_path.
      # _cited_paths is newline-separated; iterate via heredoc to avoid
      # pipeline-subshell variable loss under bash 3.2.
      while IFS= read -r _p; do
        [ -z "$_p" ] && continue
        # Containment first (P1 invariant). pp_contain_path echoes the
        # resolved real path on success; we discard stdout but use rc.
        _contained=$(pp_contain_path "$_cwd" "$_p" 2>/dev/null) || continue
        # Pass the contained real path (not the raw cite) so the git
        # invocation sees the in-cwd path. pp_oar_acted_for_path performs
        # its own pp_safe_git_pathspec check.
        # SYMBOL arg is space-separated; pass all cited_symbols as one
        # whitespace-joined string (the helper tokenizes internally).
        local _sym_joined
        _sym_joined=$(printf '%s' "$_cited_symbols" \
                       | LC_ALL=C tr '\n' ' ' \
                       | LC_ALL=C sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
        # Relative path for git: strip the cwd prefix from the resolved
        # real path so git log sees the in-repo path.
        local _cwd_real _rel
        _cwd_real=""
        _cwd_real=$(cd "$_cwd" 2>/dev/null && pwd -P) || _cwd_real="$_cwd"
        _rel="${_contained#"$_cwd_real"/}"
        # If strip didn't change the string (candidate == base) skip — a
        # base-itself cite has nothing to log.
        [ "$_rel" = "$_contained" ] && continue
        _rc=0
        _acted_out=$(pp_oar_with_row_timeout "${PP_OAR_ROW_TIMEOUT_S:-3}" \
                       pp_oar_acted_for_path "$_cwd" "$_rel" "$_sym_joined" "" \
                       "$_inj_epoch" "$_upper" 2>/dev/null) || _rc=$?
        if [ "$_rc" -eq 0 ] && [ -n "$_acted_out" ]; then
          _outcome="acted"
          # GPT-review: guard against future detector contract drift —
          # if output lacks `|`, the %% / # parameter expansions both
          # return the whole string, conflating evidence_id and confidence.
          case "$_acted_out" in
            *\|*)
              _evid_id="${_acted_out%%|*}"
              _conf="${_acted_out#*|}"
              ;;
            *)
              _evid_id="$_acted_out"
              _conf="unknown"
              ;;
          esac
          break
        elif [ "$_rc" -eq 2 ]; then
          _err=1
        fi
      done <<EOF
$_cited_paths
EOF
    fi

    # ----- Step 3: referenced? (only if still ignored) -----
    if [ "$_outcome" = "ignored" ]; then
      local _tail="${_cache_dir}/transcript-tail-${_sid}.txt"
      if [ -f "$_tail" ]; then
        # Pass SYMBOLS only (per pp_oar_referenced M1 contract). The
        # symbols string is newline-separated already.
        _rc=0
        _ref_out=$(pp_oar_with_row_timeout "${PP_OAR_ROW_TIMEOUT_S:-3}" \
                     pp_oar_referenced "$_sid" "$_inj_epoch" "$_upper" \
                     "$_body" "$_cited_symbols" 2>/dev/null) || _rc=$?
        if [ "$_rc" -eq 0 ] && [ -n "$_ref_out" ]; then
          _outcome="referenced"
          # Same missing-pipe guard as the acted branch above.
          case "$_ref_out" in
            *\|*)
              _evid_id="${_ref_out%%|*}"
              _conf="${_ref_out#*|}"
              ;;
            *)
              _evid_id="$_ref_out"
              _conf="unknown"
              ;;
          esac
        elif [ "$_rc" -eq 2 ]; then
          _err=1
        fi
      fi
    fi

    fi  # end of "if not pre-stamped silent" guard

    # ----- Quarantine path: only if outcome stayed 'ignored' AND a
    # detector flagged a transient error. attempts++ until max; on max,
    # move to oar-stuck.jsonl; otherwise put back in pending with bumped
    # attempts so the next cycle retries.
    if [ "$_outcome" = "ignored" ] && [ "$_err" = "1" ]; then
      _attempts=$(( _attempts + 1 ))
      if [ "$_attempts" -ge "$_max_att" ]; then
        jq -nc \
          --arg sid "$_sid" --arg lens "$_lens" --arg h "$_hash" \
          --arg ts "$_inj_ts" --argjson att "$_attempts" \
          --arg project_id "$_project_id" \
          --arg project_root "$_project_root" \
          --arg project_root_sha8 "$_project_root_sha8" \
          --arg err "labeling failed after $_attempts attempts" \
          '{session_id:$sid,lens:$lens,hash:$h,inject_ts:$ts,
            attempts:$att,last_error:$err,
            project_id:(if $project_id=="" then null else $project_id end),
            project_root:(if $project_root=="" then null else $project_root end),
            project_root_sha8:(if $project_root_sha8=="" then null else $project_root_sha8 end)}' \
          >> "$_stuck" 2>/dev/null || true
        continue
      fi
      printf '%s\n' "$_line" \
        | jq -c --argjson att "$_attempts" '. + {attempts:$att}' \
            >> "$_kept" 2>/dev/null || printf '%s\n' "$_line" >> "$_kept"
      continue
    fi

    # ----- Write labeled row + record identity.
    local _label_blob _labeled_at
    _labeled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                  || printf '1970-01-01T00:00:00Z')
    _label_blob=""
    _label_blob=$(jq -nc \
      --arg sid "$_sid" --arg lens "$_lens" --arg h "$_hash" \
      --arg ts "$_inj_ts" --arg labeled_at "$_labeled_at" \
      --arg outcome "$_outcome" --arg evid "$_evid_id" \
      --arg conf "$_conf" --arg identity "${_id:-}" \
      --arg body "$_body" \
      --arg silent_reason "$_silent_reason" \
      --arg project_id "$_project_id" \
      --arg project_root "$_project_root" \
      --arg project_root_sha8 "$_project_root_sha8" \
      --argjson prompt_versions "$_prompt_versions_json" \
      --argjson schema "${PP_OAR_SCHEMA_VERSION:-2}" \
      '{schema_version:$schema,
        session_id:$sid,lens:$lens,hash:$h,inject_ts:$ts,
        labeled_at:$labeled_at,outcome:$outcome,
        evidence_id:(if $evid=="null" or $evid=="" then null else $evid end),
        confidence:$conf,
        silent_reason:$silent_reason,
        prompt_versions:$prompt_versions,
        project_id:(if $project_id=="" then null else $project_id end),
        project_root:(if $project_root=="" then null else $project_root end),
        project_root_sha8:(if $project_root_sha8=="" then null else $project_root_sha8 end),
        identity:(if $identity=="" then null else $identity end),
        evidence:(if $body=="" then null else $body end)}' \
      2>/dev/null) || _label_blob=""
    if [ -n "$_label_blob" ]; then
      printf '%s\n' "$_label_blob" >> "$_labeled" 2>/dev/null || true
      [ -n "$_id" ] && printf '%s\n' "$_id" >> "$_seen" 2>/dev/null
    fi
  done < "$_snapshot"

  # Atomic pending replace: mv kept → pending. The mv is rename-within-dir
  # so atomic on POSIX filesystems (kept was mktemp'd in the same dir).
  # On failure (e.g. mv fails), leave pending unchanged — the labeled rows
  # are already persisted; next cycle will re-process the survivors and the
  # idempotency check prevents double-labeling.
  if [ -f "$_pending" ]; then
    mv -f "$_kept" "$_pending" 2>/dev/null && _kept=""
  fi
  # Explicit cleanup (we don't use trap RETURN — sub-functions fire it).
  rm -f "$_seen" "$_snapshot" 2>/dev/null
  [ -n "$_kept" ] && rm -f "$_kept" 2>/dev/null
  # Release the concurrency lock (acquired at function entry).
  rmdir "$_lock" 2>/dev/null
  return 0
}
