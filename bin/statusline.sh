#!/usr/bin/env bash
# Claude Code statusLine — Magical Aladdin-palette edition
# Reads JSON from stdin, prints animated colored line.
# Designed for refreshInterval: 2 in settings.json.
# Spec: ~/.claude/specs/2026-05-11-claude-code-statusline-design.md

# Locale handling: the awk float-parse bug (de_DE.UTF-8 comma decimal) lives
# on a small handful of specific awk calls (load_1m parsing at ~line 282).
# Round 1 of the Ralph loop set `LC_ALL=C; export LC_ALL` file-globally, but
# that broke the progress-bar render — BSD `tr ' ' '▰'` is single-byte under
# C locale and emits only the first byte (0xE2) of the 3-byte U+25B0 char,
# garbling the most prominent visual element of the status line (R2 H1 — caught
# by code-reviewer + GPT-5.2). Scope the C-locale fix to the awk calls that
# actually need it (inline `LC_ALL=C awk ...`) and leave the surrounding shell
# in the user's locale so `tr`, `date`, and emoji output stay correct.

# Portable mtime helper. `stat -f %m FILE` is BSD/macOS only; GNU stat
# interprets -f as "filesystem info, ignore format" and dumps multi-line
# garbage that breaks the surrounding arithmetic. Try GNU `-c %Y` first
# then fall back to BSD `-f %m`. Returns the epoch mtime, or empty string
# if neither works. Caller is expected to default with ${var:-0}.
pp_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Pair Polymath — load config + libs
_pp_bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_pp_bin_dir/../lib/config.sh"
# shellcheck disable=SC1091
. "$_pp_bin_dir/../lib/budget.sh"
# shellcheck disable=SC1091
. "$_pp_bin_dir/../lib/lens-loader.sh"
# shellcheck disable=SC1091
. "$_pp_bin_dir/../lib/grounding.sh"
# shellcheck disable=SC1091
. "$_pp_bin_dir/../lib/prompt-loader.sh"
# shellcheck disable=SC1091
. "$_pp_bin_dir/../lib/metrics.sh"
# shellcheck disable=SC1091
. "$_pp_bin_dir/../lib/citations.sh"

# Load lens registry from lenses/*.json (built-in + user overrides).
# Populates PP_LENS_{COUNT,IDS,HATS,FOCUS,COLOR,ENABLED}.
pp_load_lenses

input=$(cat)

# --- Animation tick (4-frame, 2s per frame) ---
tick=$(( ($(date +%s) / 2) % 4 ))
half=$(( tick % 2 ))

# --- ANSI palette (256-color) — semantic, restrained ---
ESC=$'\033'
R="${ESC}[0m"
DIM_A="${ESC}[2m"
BOLD="${ESC}[1m"

# Identity (calmer purples)
SOFT_PURPLE="${ESC}[38;5;139m"
DIRTY="${ESC}[38;5;167m"

# Money — the thing that matters most, draws the eye
AMBER="${ESC}[38;5;215m"

# Health thresholds (less saturated than before)
SOFT_GREEN="${ESC}[38;5;108m"
SOFT_AMBER="${ESC}[38;5;179m"
SOFT_CRIMSON="${ESC}[38;5;167m"

# Reading surface
CREAM="${ESC}[38;5;252m"
DIM_GRAY="${ESC}[38;5;243m"
SUBTLE="${ESC}[38;5;240m"

# Info bullets
CYAN_SOFT="${ESC}[38;5;109m"

# Animation accents (kept for sparkle)
LAVENDER="${ESC}[38;5;183m"
SKY="${ESC}[38;5;117m"
BRONZE="${ESC}[38;5;144m"
MAGENTA="${ESC}[38;5;176m"

# Legacy aliases for back-compat with rest of script (will refactor below)
PURPLE="$SOFT_PURPLE"
TURQUOISE="$CYAN_SOFT"
CRIMSON="$SOFT_CRIMSON"
GOLDENROD="$SOFT_AMBER"
GREEN="$SOFT_GREEN"
GOLD="$SOFT_AMBER"
GRAY="$DIM_GRAY"
SAFFRON="$AMBER"

# Portable timeout wrapper — uses timeout/gtimeout if installed, else passes through
run_llm() {
  local timeout_s="${1:-60}"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" llm "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_s" llm "$@"
  else
    llm "$@"
  fi
}

# budget_inc + budget_reserve live in lib/budget.sh (sourced at top of file).

# --- Extract JSON fields (single jq call, portable while-read loop) ---
F=()
while IFS= read -r f; do F+=("$f"); done < <(echo "$input" | jq -r '
  .workspace.current_dir // .cwd // "-",
  .model.display_name // "-",
  .context_window.used_percentage // 0,
  .cost.total_cost_usd // 0,
  .cost.total_duration_ms // 0,
  .effort.level // "-",
  .output_style.name // "-",
  .rate_limits.five_hour.used_percentage // -1,
  .rate_limits.five_hour.resets_at // 0,
  .context_window.current_usage.cache_read_input_tokens // 0,
  .context_window.current_usage.cache_creation_input_tokens // 0,
  .context_window.current_usage.input_tokens // 0,
  .session_id // "default",
  .rate_limits.seven_day.used_percentage // -1,
  .rate_limits.seven_day.resets_at // 0
')
cwd="${F[0]:--}"
model="${F[1]:--}"
ctx_pct="${F[2]:-0}"
cost="${F[3]:-0}"
duration_ms="${F[4]:-0}"
effort="${F[5]:--}"
style="${F[6]:--}"
limit_5h="${F[7]:--1}"
limit_5h_reset="${F[8]:-0}"
cache_read="${F[9]:-0}"
cache_create="${F[10]:-0}"
input_tokens="${F[11]:-0}"
session_id="${F[12]:-default}"
limit_7d="${F[13]:--1}"
limit_7d_reset="${F[14]:-0}"

# Canonicalize + sanitize session_id. Strip anything that could escape paths,
# inject newlines, or otherwise corrupt lock/cache filenames built from it.
# Cap length so a hostile/long ID can't blow out filesystem limits.
session_id="${session_id:-${SESSION_ID:-default}}"
session_id=$(printf '%s' "$session_id" | tr -cd 'a-zA-Z0-9._-' | cut -c1-64)
[ -z "$session_id" ] && session_id="default"

# --- Git branch + dirty marker ---
branch=""
dirty=""
if [ "$cwd" != "-" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$cwd" -c core.fsmonitor=false symbolic-ref --short HEAD 2>/dev/null)
  if git -C "$cwd" -c core.fsmonitor=false status --porcelain 2>/dev/null | head -1 | grep -q .; then
    dirty="●"
  fi
fi

line=""

# 1. Leading magical icon — 4-frame cycle (lamp → wand → sparkle → comet)
case $tick in
  0) lead="🪔" ;;
  1) lead="🪄" ;;
  2) lead="✨" ;;
  3) lead="💫" ;;
esac
line="$lead"

# 2. Branch + dirty — soft purple identity, crimson dot only on dirty
if [ -n "$branch" ]; then
  if [ -n "$dirty" ]; then
    line="${line} ${SOFT_PURPLE}(${branch}${DIRTY}${dirty}${SOFT_PURPLE})${R}"
  else
    line="${line} ${SOFT_PURPLE}(${branch})${R}"
  fi
fi

# 3. Effort badge — dim brackets with cream value (quiet, visible)
if [ "$effort" != "-" ]; then
  line="${line} ${SUBTLE}[${R}${CREAM}${effort}${R}${SUBTLE}]${R}"
fi

# 5. Context % — clean ▰▱ bar (solid/outline), zone-colored, no emoji clutter
pct=$(printf "%.0f" "$ctx_pct" 2>/dev/null || echo 0)
if [ "$pct" -gt 0 ]; then
  BAR_WIDTH=5
  filled_count=$((pct * BAR_WIDTH / 100))
  [ "$filled_count" -gt "$BAR_WIDTH" ] && filled_count=$BAR_WIDTH
  empty_count=$((BAR_WIDTH - filled_count))

  if [ "$pct" -ge 90 ]; then bar_color=$SOFT_CRIMSON
  elif [ "$pct" -ge 70 ]; then bar_color=$SOFT_AMBER
  else bar_color=$SOFT_GREEN
  fi

  filled_str=""
  [ "$filled_count" -gt 0 ] && filled_str=$(printf "%${filled_count}s" | tr ' ' '▰')
  empty_str=""
  [ "$empty_count" -gt 0 ] && empty_str=$(printf "%${empty_count}s" | tr ' ' '▱')

  line="${line} ${bar_color}${filled_str}${SUBTLE}${empty_str}${R} ${CREAM}${pct}%${R}"
fi

# 6. Cost — AMBER bold (visual anchor). The $ sign is its own indicator.
# Use awk -v for safe interpolation (cost is untrusted JSON; never inline into program).
cost_cents=$(awk -v c="$cost" 'BEGIN { printf "%d", c * 100 }' 2>/dev/null || echo 0)
if [ "$cost_cents" -ge 1 ]; then
  cost_fmt=$(awk -v c="$cost" 'BEGIN { printf "%.2f", c }')
  line="${line} ${BOLD}${AMBER}\$${cost_fmt}${R}"
fi

# 7. Duration removed per user — already covered by burn rate signal.

# 8. Cache hit % (only when <90%, signals prompt cache underperforming)
if [ "$cache_read" -gt 0 ] 2>/dev/null; then
  total_in=$((input_tokens + cache_create + cache_read))
  if [ "$total_in" -gt 0 ]; then
    cache_pct=$(( cache_read * 100 / total_in ))
    if [ "$cache_pct" -lt 70 ]; then
      line="${line} ${BRONZE}cache:${cache_pct}%${R}"
    fi
  fi
fi

# 9. Burn rate (>$10/hr) — crimson, the /hr suffix is the indicator
if [ "$duration_ms" -gt 60000 ] && [ "$cost_cents" -gt 0 ] 2>/dev/null; then
  hourly_int=$(awk -v c="$cost" -v d="$duration_ms" 'BEGIN { if (d > 0) printf "%d", c * 3600000 / d; else printf "0" }' 2>/dev/null || echo 0)
  if [ "$hourly_int" -ge 10 ]; then
    line="${line} ${SOFT_CRIMSON}\$${hourly_int}/hr${R}"
  fi
fi

# 10. 5h rate limit (>80%) — hourglass icon
if [ "$limit_5h" != "-1" ]; then
  l5=$(printf "%.0f" "$limit_5h" 2>/dev/null || echo 0)
  if [ "$l5" -gt 80 ]; then
    line="${line} ⏳${CRIMSON}${l5}%${R}"
  fi
fi

# 10b. 7d weekly rate limit — show when >50% with reset countdown
if [ "$limit_7d" != "-1" ]; then
  l7=$(printf "%.0f" "$limit_7d" 2>/dev/null || echo 0)
  if [ "$l7" -gt 50 ]; then
    if [ "$l7" -gt 85 ]; then color7=$SOFT_CRIMSON
    else color7=$SOFT_AMBER
    fi
    if [ "$limit_7d_reset" -gt 0 ] 2>/dev/null; then
      now7=$(date +%s)
      diff7=$((limit_7d_reset - now7))
      if [ "$diff7" -gt 0 ] && [ "$diff7" -le 604800 ]; then
        d7=$((diff7 / 86400))
        h7=$(( (diff7 % 86400) / 3600 ))
        if [ "$d7" -gt 0 ]; then
          line="${line} ${color7}7d:${l7}%·${d7}d${h7}h${R}"
        else
          line="${line} ${color7}7d:${l7}%·${h7}h${R}"
        fi
      else
        line="${line} ${color7}7d:${l7}%${R}"
      fi
    else
      line="${line} ${color7}7d:${l7}%${R}"
    fi
  fi
fi

# 11. PR count for current repo (cached 10min via gh CLI, fire-and-forget refresh)
if [ -n "$branch" ] && command -v gh >/dev/null 2>&1; then
  repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$repo_root" ]; then
    # Ubuntu ships sha1sum, not shasum. Without a fallback, this line
    # silently produced an empty cache_key on Linux → every repo on the
    # box shared one cache file at /tmp/cc-pr-.cache (Ralph round 2 BUG 2).
    cache_key=$(echo "$repo_root" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -d' ' -f1)
    cache_file="/tmp/cc-pr-${cache_key}.cache"
    if [ ! -f "$cache_file" ] || [ $(($(date +%s) - $(pp_mtime "$cache_file" || echo 0))) -gt 600 ]; then
      ( cd "$repo_root" && gh pr list --json number 2>/dev/null | jq -r 'length' > "$cache_file" 2>/dev/null ) &
    fi
    if [ -f "$cache_file" ]; then
      pr_count=$(cat "$cache_file" 2>/dev/null)
      if [ -n "$pr_count" ] && [ "$pr_count" -gt 0 ] 2>/dev/null; then
        line="${line} ${SKY}PR:${pr_count}${R}"
      fi
    fi
  fi
fi

# 12. CPU load — only at critical (>5.0). Saves space; line 2 needs the room.
# `sysctl -n vm.loadavg` outputs a float (e.g. "0.05"); under de_DE.UTF-8
# awk's printf "%d" of a float can mis-parse comma-decimal separators.
# LC_ALL=C is scoped to the awk that does the actual float math (R2 H1 scope).
load_1m=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
if [ -n "$load_1m" ]; then
  load_int=$(LC_ALL=C awk -v l="$load_1m" 'BEGIN { printf "%d", l * 10 }')
  if [ "$load_int" -ge 50 ]; then
    line="${line} ${SUBTLE}cpu${R} ${SOFT_CRIMSON}${load_1m}${R}"
  fi
fi

# 13. RAM % used — parsed from vm_stat
ram_pct=$(vm_stat 2>/dev/null | awk '
  /page size of/ { ps = $8 }
  /Pages free:/ { gsub(/\./, "", $3); f = $3 }
  /Pages inactive:/ { gsub(/\./, "", $3); ina = $3 }
  /Pages active:/ { gsub(/\./, "", $3); a = $3 }
  /Pages wired down:/ { gsub(/\./, "", $4); w = $4 }
  /Pages occupied by compressor:/ { gsub(/\./, "", $5); c = $5 }
  END {
    total = f + ina + a + w + c
    used = a + w + c
    if (total > 0) printf "%d", (used * 100) / total
  }
')
if [ -n "$ram_pct" ] && [ "$ram_pct" -ge 85 ]; then
  line="${line} ${SUBTLE}ram${R} ${SOFT_CRIMSON}${ram_pct}${R}"
fi

# 14. Trail sparkle dropped from default to save 2 cells for the insight line.
# To re-enable: case $tick in 0) trail="⋆";; 1) trail="✦";; ... esac; line="${line} ${MAGENTA}${trail}${R}"

# === Line 2: LLM-analyzed HN digests (refreshed every 30min in background) ===
TIP_CACHE="${HOME}/.claude/cache/cc-tips.txt"
# TIP_LOCK was previously keyed per-session, but TIP_CACHE is a single global
# file — so two Claude Code windows with different session_ids both passed
# the lock check independently and raced the cache write. The second writer's
# `mv` silently clobbered the first (Ralph round 2 BUG 4). Now: lock scope
# matches cache scope (global).
TIP_LOCK="/tmp/cc-tips-fetch.lock"
mkdir -p "${HOME}/.claude/cache" 2>/dev/null

cache_age=$(($(date +%s) - $(pp_mtime "$TIP_CACHE" || echo 0)))
if [ ! -f "$TIP_CACHE" ] || [ "$cache_age" -gt 1800 ]; then
  # Atomic lock primitive (Ralph R2 H3). The previous
  # `[ ! -f "$LOCK" ] && touch "$LOCK"` was a check-then-touch TOCTOU race —
  # two parallel statuslines could both see absent + both touch + both spawn
  # the background fetcher → mv-clobber on TIP_CACHE. mkdir is atomic on all
  # POSIX filesystems; the matching pattern is already used in lib/budget.sh.
  # Stale takeover after 180s (orphaned crash recovery).
  TIP_LOCK_DIR="${TIP_LOCK}.d"
  lock_age=$(($(date +%s) - $(pp_mtime "$TIP_LOCK_DIR" || echo 0)))
  if [ "$lock_age" -gt 180 ]; then
    rmdir "$TIP_LOCK_DIR" 2>/dev/null
  fi
  if mkdir "$TIP_LOCK_DIR" 2>/dev/null; then
    (
      stories=$(curl -s --max-time 8 "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=15" 2>/dev/null \
        | jq -r '.hits[] | "- \(.title)" + (if (.url // "") != "" then " — \(.url)" else "" end)' 2>/dev/null)

      # Portable timeout (macOS lacks `timeout`; gtimeout from coreutils if installed)
      TO=""
      command -v timeout >/dev/null 2>&1 && TO="timeout 40"
      [ -z "$TO" ] && command -v gtimeout >/dev/null 2>&1 && TO="gtimeout 40"

      # Pull project context (CLAUDE.md) for domain-aware tip personalization
      project_ctx=""
      if [ -f "$cwd/CLAUDE.md" ]; then
        project_ctx=$(head -c 2000 "$cwd/CLAUDE.md")
      fi
      # Recent commits help the LLM understand active work
      recent_commits=""
      if [ "$cwd" != "-" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
        recent_commits=$(git -C "$cwd" log -5 --format='%s' 2>/dev/null)
      fi

      # Also pull ArXiv recent cs.AI papers as a second source (research-leaning)
      arxiv_titles=$(curl -s --max-time 5 "http://export.arxiv.org/api/query?search_query=cat:cs.AI+OR+cat:cs.HC&sortBy=submittedDate&sortOrder=descending&max_results=10" 2>/dev/null | \
        grep -oE '<title>[^<]+</title>' | sed 's/<\/\?title>//g' | tail -10 | head -10)

      if [ -n "$stories" ] && command -v llm >/dev/null 2>&1; then
        tip_digest_sys=$(pp_render_prompt tip-digest)
        # Skip the LLM call entirely if the prompt is missing (review fix M1).
        # Empty $tip_digest_sys means pp_render_prompt failed; we already logged
        # to stderr. Falling through with -s "" would burn budget on a no-op.
        digest=""
        [ -n "$tip_digest_sys" ] && digest=$(printf "USER PROJECT CONTEXT (from CLAUDE.md):\n%s\n\nRECENT WORK (last 5 commits):\n%s\n\nHN STORIES:\n%s\n\nARXIV PAPERS (cs.AI / cs.HC):\n%s" "$project_ctx" "$recent_commits" "$stories" "$arxiv_titles" | run_llm 40 -m gpt-5-mini -s "$tip_digest_sys" 2>/dev/null)

        if [ -n "$digest" ]; then
          echo "$digest" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*[-*0-9.)]*[[:space:]]*//' > "${TIP_CACHE}.tmp"
          [ -s "${TIP_CACHE}.tmp" ] && mv "${TIP_CACHE}.tmp" "$TIP_CACHE"
        fi
      elif [ -n "$stories" ]; then
        # Fallback: no llm CLI, just save raw titles
        echo "$stories" | sed 's/^- //; s/ — http.*$//' > "${TIP_CACHE}.tmp"
        [ -s "${TIP_CACHE}.tmp" ] && mv "${TIP_CACHE}.tmp" "$TIP_CACHE"
      fi
      # Clean up the .tmp + atomic lock dir (the lock is a dir now, not a file)
      rm -f "${TIP_CACHE}.tmp"
      rmdir "$TIP_LOCK_DIR" 2>/dev/null
    ) >/dev/null 2>&1 &
  fi
fi

# Resolve tip — split topic and body for slot-based display
tip_topic=""
tip_body=""
if [ -f "$TIP_CACHE" ] && [ -s "$TIP_CACHE" ]; then
  count=$(wc -l < "$TIP_CACHE" | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    # Rotate slowly (90s per tip) so user can read across multiple slot cycles
    idx=$(( ($(date +%s) / 90) % count + 1 ))
    tip=$(sed -n "${idx}p" "$TIP_CACHE")
    if [ -n "$tip" ] && echo "$tip" | grep -q '|||'; then
      tip_topic="${tip%%|||*}"
      tip_body="${tip#*|||}"
    fi
  fi
fi

# === Line 4: LLM monitor — pair-programmer watching the transcript ===
# Reads last ~6KB of transcript, asks LLM to surface 1 actionable observation.
# Refresh: PP_PARALLEL_INTERVAL_S. Models + cap come from config/default.env (override
# in ~/.claude/pair-polymath/config/user.env). Worst-case 23 calls reserved per cycle
# (1p + 7a + 1c + 7r + 7e). Cap binds at ~152 cycles/day at PP_MAX_DAILY_CALLS=3500.
# PP_MODEL, PP_MODEL_DEEP, PP_MODEL_CRITIQUE, PP_PARALLEL_INTERVAL_S, PP_MAX_DAILY_CALLS
# all sourced from config. PP_BUDGET_FILE comes from lib/budget.sh.
PP_LAST_PARALLEL="${PP_CACHE_DIR}/pp-last-parallel-${session_id}.txt"
PP_LOCK="/tmp/pp-fetch-${session_id}.lock"

# Per-lens cache files are populated by the parallel run below and read by the
# display + hook. Lens metadata lives in $PP_LENS_IDS/HATS/FOCUS/COLOR — loaded
# from lenses/*.json at the top of this file.

transcript_path=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

# Active/passive mode: detect idle terminal via transcript mtime.
# If > PP_IDLE_THRESHOLD_S since last activity → passive mode, skip LLM generation.
# Display cycle still shows last cached observations.
session_idle_s=0
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  session_idle_s=$(($(date +%s) - $(pp_mtime "$transcript_path" || echo $(date +%s))))
fi
is_active=1
[ "$session_idle_s" -gt "${PP_IDLE_THRESHOLD_S:-1800}" ] && is_active=0

# Check if parallel cycle is due
last_parallel=$(cat "$PP_LAST_PARALLEL" 2>/dev/null || echo 0)
parallel_age=$(($(date +%s) - last_parallel))

# === PP_EVAL_MODE — eval harness short-circuit ===
# When set to "1", force the cycle gates open (idle/interval/cache-staleness)
# so a single statusline invocation deterministically runs ONE full cycle and
# emits the raw lens observations to stdout. Used by test/eval/run-eval.sh to
# replay frozen fixtures. No effect when unset — normal users never see this
# path. Honors PP_EXTERNAL_LLM=0 for offline/dry-run runs.
if [ "${PP_EVAL_MODE:-0}" = "1" ]; then
  is_active=1
  parallel_age=$((PP_PARALLEL_INTERVAL_S + 1))
fi

if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] \
    && [ "$is_active" -eq 1 ] \
    && [ "${PP_EXTERNAL_LLM:-1}" = "1" ] \
    && [ "$parallel_age" -gt "$PP_PARALLEL_INTERVAL_S" ]; then
  mon_lock_age=$(($(date +%s) - $(pp_mtime "$PP_LOCK" || echo 0)))
  # Atomic acquire of cycle lock: mkdir succeeds for exactly one caller.
  # If a stale lock dir (>5 min) blocks us, force-take it once.
  acquired=0
  if mkdir "$PP_LOCK" 2>/dev/null; then
    acquired=1
  elif [ "$mon_lock_age" -gt 300 ]; then
    rm -rf "$PP_LOCK" 2>/dev/null
    mkdir "$PP_LOCK" 2>/dev/null && acquired=1
  fi
  if [ "$acquired" = "1" ]; then
    echo "$(date +%s)" > "$PP_LAST_PARALLEL"
    (
      # Split traps covering metrics flush + the cycle lock (now a dir) +
      # the unified budget lock. Order matters: flush metrics BEFORE
      # releasing the cycle lock so a SIGTERM can't orphan the tmp file
      # OR lose the cost data (review fix R2-M1). metrics_flush_cycle is
      # idempotent on missing tmp, so a clean exit running through here
      # AND through the explicit call at end-of-subshell is safe.
      #
      # Round-3 fix R3-PR10-2: previous design used a single trap for
      # EXIT INT TERM HUP — but on INT/TERM/HUP the trap body runs cleanup
      # and the subshell KEEPS GOING with locks already released, racing
      # any next cycle that re-acquires them. Now we cleanup-then-exit
      # 128+N (bash convention) on each kill signal. EXIT still cleans up
      # only since EXIT already implies exit.
      _pp_cycle_cleanup() {
        metrics_flush_cycle "$session_id" 2>/dev/null
        rmdir "$PP_LOCK" 2>/dev/null || rm -rf "$PP_LOCK" 2>/dev/null
        # NOTE: the cycle subshell holds the budget lock only transiently
        # inside budget_reserve / budget_inc (released before those functions
        # return). When this trap fires, the subshell is NOT holding the
        # budget lock — so rmdir-ing it here releases a lock that may be
        # currently held by a concurrent statusline invocation's budget call,
        # corrupting its atomicity. (Ralph round 2 H3.) Do nothing with the
        # budget lock here; lib/budget.sh manages its own lifecycle.
      }
      trap _pp_cycle_cleanup EXIT
      trap '_pp_cycle_cleanup; exit 130' INT
      trap '_pp_cycle_cleanup; exit 143' TERM
      trap '_pp_cycle_cleanup; exit 129' HUP

      # === Pre-flight: gather grounded facts (shared by all 5 agents) ===
      activity_tail=$(tail -c 5000 "$transcript_path" 2>/dev/null)

      recent_tools=$(tail -n 200 "$transcript_path" 2>/dev/null | jq -r '
        select(.message.content | type == "array") |
        .message.content[] | select(.type == "tool_use") |
        "TOOL(\(.name // "?")): \(.input | tostring | .[0:120])"
      ' 2>/dev/null | tail -15)

      # Last test/lint run captured by cache-test-result.sh PostToolUse hook
      test_state=""
      test_cache_file="${HOME}/.claude/cache/cc-test-${session_id}.cache"
      if [ -f "$test_cache_file" ]; then
        test_age=$(($(date +%s) - $(pp_mtime "$test_cache_file" || echo 0)))
        if [ "$test_age" -lt 1800 ]; then
          test_state=$(cat "$test_cache_file" 2>/dev/null | head -c 1800)
        fi
      fi

      # === Extract recent USER messages — strongest signal of current intent ===
      recent_user_messages=$(tail -n 500 "$transcript_path" 2>/dev/null \
        | jq -r 'select((.type // .message.role // "") == "user") | ((.message.content // .text // "") | tostring | .[0:600])' 2>/dev/null \
        | grep -v "^$" | grep -v "^null$" | tail -5)

      git_status=""
      git_log=""
      git_diff_stat=""
      git_recent_files=""
      if [ "$cwd" != "-" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
        git_status=$(git -C "$cwd" status --short 2>/dev/null | head -20)
        git_log=$(git -C "$cwd" log -8 --oneline 2>/dev/null)
        git_diff_stat=$(git -C "$cwd" diff --stat HEAD~3..HEAD 2>/dev/null | tail -15)
        # Recently modified tracked files (most useful for picking a file to read)
        git_recent_files=$(git -C "$cwd" diff --name-only HEAD~5..HEAD 2>/dev/null | head -15)
      fi

      # gh CLI: open PRs (cached 10min) and recent CI runs (cached 5min)
      gh_prs=""
      gh_ci=""
      repo_key=""
      repo_root=""
      if [ "$cwd" != "-" ] && command -v gh >/dev/null 2>&1 \
          && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
        repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
        if [ -n "$repo_root" ]; then
          # Same shasum-vs-sha1sum portability fallback as line ~255.
          repo_key=$(echo "$repo_root" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -d' ' -f1 | head -c 12)

          # PR list — fire-and-forget refresh, read latest cached
          pr_cache="${HOME}/.claude/cache/cc-pr-detail-${repo_key}.cache"
          pr_age=$(($(date +%s) - $(pp_mtime "$pr_cache" || echo 0)))
          if [ ! -f "$pr_cache" ] || [ "$pr_age" -gt 600 ]; then
            # FIX (advisor #3): atomic write — tmp file + mv
            ( cd "$repo_root" && gh pr list --limit 10 --json number,title,state,isDraft,statusCheckRollup 2>/dev/null \
              | jq -r '.[] | "PR#\(.number) [\(.state)\(if .isDraft then " DRAFT" else "" end)] \(.title) — CI: \([.statusCheckRollup[]?.state // "?"] | join(","))"' \
              > "${pr_cache}.tmp" 2>/dev/null && mv "${pr_cache}.tmp" "$pr_cache" ) &
          fi
          [ -f "$pr_cache" ] && gh_prs=$(cat "$pr_cache" 2>/dev/null | head -10)

          # CI run list — fire-and-forget refresh, 5min TTL
          ci_cache="${HOME}/.claude/cache/cc-ci-${repo_key}.cache"
          ci_age=$(($(date +%s) - $(pp_mtime "$ci_cache" || echo 0)))
          if [ ! -f "$ci_cache" ] || [ "$ci_age" -gt 300 ]; then
            # FIX (advisor #3): atomic write — tmp file + mv
            ( cd "$repo_root" && gh run list --limit 5 --json status,conclusion,workflowName,createdAt 2>/dev/null \
              | jq -r '.[] | "\(.workflowName): \(.status)/\(.conclusion // "?")"' \
              > "${ci_cache}.tmp" 2>/dev/null && mv "${ci_cache}.tmp" "$ci_cache" ) &
          fi
          [ -f "$ci_cache" ] && gh_ci=$(cat "$ci_cache" 2>/dev/null | head -5)
        fi
      fi

      cwd_ls=""
      [ "$cwd" != "-" ] && cwd_ls=$(ls -1 "$cwd" 2>/dev/null | head -30)

      # Memory: per-project (persistent) + per-session (immediate)
      # Same shasum/sha1sum portability fallback as lines ~266 and ~509 —
      # missed by R1 (Ralph R2 H/L2: Ubuntu has only sha1sum, would silently
      # produce empty project_key → all projects collide on history files).
      project_key=$(echo "$cwd" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -d' ' -f1 | head -c 12)
      HIST_FILE_PROJECT="${HOME}/.claude/cache/cc-monitor-history-project-${project_key}.txt"
      HIST_FILE_SESSION="${HOME}/.claude/cache/cc-monitor-history-${session_id}.txt"
      prev_session=$(tail -10 "$HIST_FILE_SESSION" 2>/dev/null)
      prev_project=$(tail -20 "$HIST_FILE_PROJECT" 2>/dev/null)
      prev_observations=$(printf "%s\n%s" "$prev_session" "$prev_project" | sort -u | head -25)


      # === Reserve budget BEFORE any LLM call (planner + 7 analysts + critique + retries) ===
      # Single atomic reservation prevents the race where parallel analysts each increment
      # independently and skip counting the planner. Must wrap BOTH planner and analyst
      # fan-out so an exhausted budget skips everything.
      # FIX (review C1): reserve WORST-CASE 23 calls (base 9 + 7 retries + 7 escalation invs)
      # so the daily cap can't be bypassed by drop storms. Excess unused calls aren't refunded.
      #
      # GATE on `llm` availability (Ralph round 2 BUG 5 — caught by all 3
      # reviewers). If llm is missing, every downstream LLM call short-
      # circuits, but the 23 calls stay reserved permanently — at 5-minute
      # cycles that's 288 × 23 = 6624 phantom calls/day, eating the entire
      # PP_MAX_DAILY_CALLS=3500 cap before noon for users who never made an
      # actual API call. Skip the reservation entirely in that case.
      can_run=0
      if command -v llm >/dev/null 2>&1; then
        if budget_reserve 23; then
          can_run=1
        fi
      fi

      # Initialize per-cycle USD telemetry tmp file (P3.1). Counts each LLM
      # call by type + model; rolled up at end of cycle into metrics.jsonl.
      metrics_init "$session_id"

      if [ "$can_run" -eq 1 ]; then
      # === Stage 1: PLANNER (gpt-5-mini) — picks a file to read ===
      planner_input=$(cat <<PLAN
GIT STATUS:
$git_status

RECENTLY-CHANGED FILES:
$git_recent_files

CWD LISTING:
$cwd_ls

RECENT TOOL CALLS:
$recent_tools

TRANSCRIPT TAIL:
${activity_tail:0:2500}
PLAN
      )

      candidate_file=""
      if command -v llm >/dev/null 2>&1; then
        planner_prompt=$(pp_render_prompt planner)
        candidate_file=""
        if [ -n "$planner_prompt" ]; then
          metrics_increment_call planner gpt-5-mini
          candidate_file=$(printf "%s" "$planner_input" | run_llm 30 -m gpt-5-mini -s "$planner_prompt" 2>/dev/null | head -1 | tr -d "\"'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        fi
      fi

      # Read the chosen file (validated, 5KB cap)
      file_contents=""
      if [ -n "$candidate_file" ] && [ "$candidate_file" != "NONE" ] \
          && [ -n "$cwd" ] && [ "$cwd" != "-" ] && [ -d "$cwd" ]; then
        # Resolve + enforce repo containment via lib/grounding.sh.
        # Reject any path outside cwd (no absolute-path fallback — closes a path-traversal vector).
        file_real=$(pp_contain_path "$cwd" "$candidate_file")
        if [ -n "$file_real" ] && [ -f "$file_real" ] && [ -r "$file_real" ]; then
          file_contents=$(head -c 5000 "$file_real" 2>/dev/null)
        else
          candidate_file="NONE"  # silently reject paths outside repo
        fi
      fi

      # Extract candidate symbols from the file the planner picked, then count refs across cwd.
      # Helps the analyst verify symbols actually exist before naming them.
      candidate_symbols=""
      symbol_refs=""
      if [ -n "$file_contents" ]; then
        candidate_symbols=$(printf "%s" "$file_contents" \
          | grep -oE '(^|[[:space:]])(function|const|let|class|def)[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]+' \
          | awk '{print $NF}' | sort -u | head -15)

        if [ -n "$candidate_symbols" ] && [ "$cwd" != "-" ]; then
          while IFS= read -r sym; do
            [ -z "$sym" ] && continue
            # FIX (review I6): exclude node_modules + use -F (fixed string, not regex) — symbols are identifiers
            ref_count=$(grep -rn -F --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
                        --include='*.py' --include='*.go' --include='*.rs' \
                        --exclude-dir={node_modules,.git,dist,build,coverage,.next,.turbo,vendor} \
                        -- "$sym" "$cwd" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$ref_count" -gt 0 ]; then
              symbol_refs="${symbol_refs}${sym}: ${ref_count} refs"$'\n'
            fi
          done <<< "$candidate_symbols"
        fi
      fi

      # Compose grounded blob — USER INTENT placed FIRST as the primary anchor
      grounded=$(cat <<GROUND
=== USER RECENT MESSAGES (PRIMARY CONTEXT — focus your observation on this) ===
${recent_user_messages:-(no user messages yet)}

=== GIT STATUS (uncommitted) ===
${git_status:-(clean)}

=== RECENT COMMITS ===
${git_log:-(none)}

=== RECENT DIFF SCOPE ===
${git_diff_stat:-(none)}

=== CWD TOP-LEVEL ===
${cwd_ls:-(empty)}

=== RECENT TOOL CALLS (last 15) ===
${recent_tools:-(none)}

=== OPEN PRS (gh, cached 10min) ===
${gh_prs:-(no PRs / not a gh-tracked repo)}

=== RECENT CI RUNS (gh, cached 5min) ===
${gh_ci:-(no CI data)}

=== FILE READ (planner picked: ${candidate_file:-NONE}) ===
${file_contents:-(no file read this round)}

=== SYMBOL REFERENCE COUNTS (grep across cwd) ===
${symbol_refs:-(no symbols extracted from file read)}

=== LAST TEST/LINT RUN (≤30min, from PostToolUse hook) ===
${test_state:-(no recent test/lint runs)}

=== PREVIOUS OBSERVATIONS (do not repeat these) ===
${prev_observations:-(none yet)}

=== TRANSCRIPT TAIL (last 5KB) ===
$activity_tail
GROUND
      )

      # === Privacy log (P3.3) ===
      # Writes what we would send to OpenAI this cycle so users can verify the
      # README's "what leaves your machine" claim. Single overwriting file
      # at $PP_CACHE_DIR/last-cycle-payload.json — atomic tmp+mv inside the
      # helper. Runs AFTER grounded facts are assembled and BEFORE the analyst
      # fan-out so the snapshot matches what the analysts actually receive.
      # We use candidate_file (the planner's literal pick) rather than
      # file_real so the user sees whatever the planner returned, including
      # the "NONE" sentinel when containment rejected the path.
      pp_write_privacy_log \
        "$session_id" \
        "$activity_tail" \
        "$grounded" \
        "${candidate_file:-<none>}" \
        "${PP_LENS_COUNT:-0}" \
        "${PP_MODEL:-}" \
        "${PP_MODEL_CRITIQUE:-}" \
        2>/dev/null || true

      if [ -n "$grounded" ] && command -v llm >/dev/null 2>&1; then
        # === PARALLEL N-AGENT FAN-OUT ===
        # Run all loaded lenses in parallel subshells. Each writes to its own cache.
        # Lens metadata comes from $PP_LENS_IDS/HATS/FOCUS (loaded from lenses/*.json).
        _pp_analyst_pids=()
        for lens_idx in $(seq 0 $((PP_LENS_COUNT - 1))); do
          lens_group="${PP_LENS_IDS[$lens_idx]}"
          lens_hats="${PP_LENS_HATS[$lens_idx]}"
          lens_focus="${PP_LENS_FOCUS[$lens_idx]}"
          # Cache filenames keyed by lens id (not numeric index) — survives
          # user enabling/disabling/reordering lenses without stale-data bugs.
          PP_CACHE_LENS="${PP_CACHE_DIR}/cc-monitor-${session_id}-${lens_group}.txt"

          # === Escalation check: if this lens has 3+ consecutive drops, escalate to deep mode ===
          # Deep mode = extra lens-specific evidence-gathering (mini-planner picks files + greps)
          # before main analyst runs. Resets after one PASS.
          lens_streak_file="${HOME}/.claude/cache/cc-monitor-${session_id}-${lens_group}-streak.txt"
          lens_streak=$(cat "$lens_streak_file" 2>/dev/null || echo 0)
          is_escalated=0
          [ "$lens_streak" -ge 3 ] && [ "${PP_ENABLE_ESCALATION:-1}" = "1" ] && is_escalated=1

          # Rotate the "deep" slot (gpt-5.5) AND the "wildcard" slot (broad allowance)
          # Both rotate every cycle through PP_LENS_COUNT positions. Offset wildcard so
          # they don't always coincide (deep stays focused; wildcard is the broader one).
          deep_slot=$(( ($(date +%s) / PP_PARALLEL_INTERVAL_S) % PP_LENS_COUNT ))
          wildcard_slot=$(( (deep_slot + 2) % PP_LENS_COUNT ))
          if [ "$lens_idx" -eq "$deep_slot" ]; then
            agent_model="$PP_MODEL_DEEP"
          else
            agent_model="$PP_MODEL"
          fi
          if [ "$lens_idx" -eq "$wildcard_slot" ]; then
            relevance_directive="WILDCARD AGENT — you have 20% allowance for broader strategic observations. You may surface something the user could miss but should know, even if not directly tied to USER'S RECENT MESSAGES. Still ground it in the codebase facts you can see."
          else
            relevance_directive="FOCUSED AGENT — anchor your observation strictly to USER'S RECENT MESSAGES. Do not drift to unrelated parts of the codebase. If nothing in your lens connects to the user's active intent, output SILENT."
          fi

          (
            # Escalation pre-investigation: run BEFORE analyst when this lens has 3+ drop streak.
            lens_evidence=""
            if [ "$is_escalated" -eq 1 ]; then
              inv_sys=$(pp_render_prompt escalation-investigation)
              inv_output=""
              if [ -n "$inv_sys" ]; then
                metrics_increment_call inv gpt-5-mini
                inv_output=$(printf "%s" "$grounded" | run_llm 25 -m gpt-5-mini -s "$inv_sys" 2>/dev/null)
              fi
              # Note: counted under worst-case-23 reservation at cycle start.

              if [ -n "$inv_output" ]; then
                inv_file=$(echo "$inv_output" | grep '^FILE:' | head -1 | sed 's/^FILE:[[:space:]]*//')
                inv_grep=$(echo "$inv_output" | grep '^GREP:' | head -1 | sed 's/^GREP:[[:space:]]*//')

                # File read with containment (via lib/grounding.sh)
                if [ -n "$inv_file" ] && [ "$inv_file" != "NONE" ] && [ -d "$cwd" ]; then
                  inv_file_real=$(pp_contain_path "$cwd" "$inv_file")
                  if [ -n "$inv_file_real" ] && [ -f "$inv_file_real" ] && [ -r "$inv_file_real" ]; then
                    lens_evidence="ESCALATED FILE READ ($inv_file):
$(head -c 3000 "$inv_file_real" 2>/dev/null)

"
                  fi
                fi

                # Grep results — validated for safety + bounded via lib/grounding.sh
                if [ -n "$inv_grep" ] && [ "$inv_grep" != "NONE" ] && [ -d "$cwd" ] \
                    && pp_safe_grep_pattern "$inv_grep"; then
                  inv_hits=$(grep -rn --include='*.ts' --include='*.tsx' --include='*.js' \
                             --include='*.py' --include='*.sh' --include='*.tex' \
                             --exclude-dir={node_modules,.git,dist,build,coverage,.next,.turbo} \
                             -m 5 -E -- "$inv_grep" "$cwd" 2>/dev/null | head -5)
                  [ -n "$inv_hits" ] && lens_evidence="${lens_evidence}ESCALATED GREP ($inv_grep):
$inv_hits"
                fi
              fi
            fi

            # Append escalation evidence to the grounded blob for THIS lens only
            lens_grounded="$grounded"
            if [ -n "$lens_evidence" ]; then
              lens_grounded="$grounded

=== LENS-SPECIFIC ESCALATION EVIDENCE (this lens has 3+ consecutive drops; deeper investigation engaged) ===
$lens_evidence"
            fi

            # Phase 2.1: pull this lens's persona + worked examples (from
            # lenses/*.json extras.system_prompt_addition + extras.examples).
            # The analyst-primary.md template now uses these as the dominant
            # content; the generic scaffold is the smaller share.
            lens_system_prompt_addition="${PP_LENS_SYSTEM_PROMPT_ADDITION[$lens_idx]}"
            lens_examples="${PP_LENS_EXAMPLES[$lens_idx]}"
            lens_silent_example="${PP_LENS_SILENT_EXAMPLE[$lens_idx]}"

            analyst_prompt=$(pp_render_prompt analyst-primary)
            lens_suggestion=""
            if [ -n "$analyst_prompt" ]; then
              metrics_increment_call analyst "$agent_model"
              lens_suggestion=$(printf "%s" "$lens_grounded" | run_llm 60 -m "$agent_model" -s "$analyst_prompt" 2>/dev/null)
            fi

            # Validate + write per-lens cache
            if [ -n "$lens_suggestion" ] && [ "$lens_suggestion" != "SILENT" ]; then
              if echo "$lens_suggestion" | head -1 | grep -Eq '^[A-Z]+: .{20,}\|\|\|.{40,}$'; then
                # Atomic write: tmp+mv so the display path's `head -1` can't
                # catch a half-written line (Ralph round 2 BUG 3 + Code-rev M2).
                # Inconsistent with the rest of the file — TIP_CACHE and PR/CI
                # caches already use this pattern at lines ~343, ~495, ~506.
                printf '%s\n' "$lens_suggestion" > "${PP_CACHE_LENS}.tmp" 2>/dev/null \
                  && mv "${PP_CACHE_LENS}.tmp" "$PP_CACHE_LENS" 2>/dev/null
                # Append to histories (session + project) — appends are atomic on POSIX
                echo "$lens_suggestion" >> "$HIST_FILE_SESSION"
                echo "$lens_suggestion" >> "$HIST_FILE_PROJECT"
              fi
              # malformed → keep previous cache content untouched
            fi
            # SILENT → don't overwrite (keep previous valid observation)
          ) &
          _pp_analyst_pids+=("$!")
        done
        # Wait ONLY on the analysts — bare `wait` would also reap the
        # fire-and-forget gh PR/CI background jobs spawned at lines ~258,
        # ~495, ~506, which can hang ~30s on slow network and hold the
        # cycle lock blocking subsequent cycles (Ralph round 2 BUG 1 +
        # Code-rev L1).
        for _pp_apid in "${_pp_analyst_pids[@]}"; do
          wait "$_pp_apid" 2>/dev/null
        done

        # === SELF-CRITIQUE PASS (gpt-5, ~$0.025/call) ===
        # Reviews all lens observations against grounded facts; drops weak/hallucinated/redundant ones.
        # FIX (advisor #1): truncate per-lens output to bound token cost on big observations.
        critique_input=""
        for ci in $(seq 0 $((PP_LENS_COUNT - 1))); do
          ci_id="${PP_LENS_IDS[$ci]}"
          cf="${HOME}/.claude/cache/cc-monitor-${session_id}-${ci_id}.txt"
          if [ -f "$cf" ] && [ -s "$cf" ]; then
            obs_short=$(head -1 "$cf" | head -c 500)   # cap each lens at 500 chars
            # Critique protocol still uses lensN: tokens (not filesystem names) so the
            # verdict parser at the next loop can grep "^lens${ci}:" unchanged.
            critique_input="${critique_input}lens${ci}: ${obs_short}"$'\n'
          fi
        done

        if [ -n "$critique_input" ]; then
          critique_sys=$(pp_render_prompt critique)
          # Phase 2.2: deterministic citation allowlists. Extracted in shell
          # from the (un-truncated) grounded blob so the critique LLM can do
          # an EXACT-match check instead of fuzzy-grepping a 3KB slice that
          # may have cut OFF the citation site. Caps at 200 each — they're
          # pure context for the LLM, not template-substituted, so no
          # PP_PROMPT_VAR_ALLOWLIST change is needed.
          pp_extract_citations
          # R2 fix: when both allowlists are empty (fresh repo / cold start /
          # no FILE READ), give the model an explicit signal so it doesn't
          # have to parse two empty multiline sections to figure that out.
          # The critique prompt's EMPTY-ALLOWLIST EXCEPTION kicks in when this
          # holds — observations are then judged on concrete/grounded/non-
          # redundant only.
          critique_allowlist_note=""
          if [ -z "$_pp_valid_paths" ] && [ -z "$_pp_valid_symbols" ]; then
            critique_allowlist_note="(NOTE: both allowlists empty — fresh repo or no FILE READ. Apply EMPTY-ALLOWLIST EXCEPTION: skip citation check.)
"
          fi
          critique_data="GROUNDED FACTS:
${grounded:0:3000}

${critique_allowlist_note}VALID PATHS (only these paths exist in the grounded inputs — observations citing anything else are HALLUCINATED):
${_pp_valid_paths}

VALID SYMBOLS (only these identifiers appear in FILE READ — observations citing anything else are [unverified] or HALLUCINATED):
${_pp_valid_symbols}

OBSERVATIONS TO JUDGE:
$critique_input"
          critique_output=""
          if [ -n "$critique_sys" ]; then
            metrics_increment_call critique "$PP_MODEL_CRITIQUE"
            critique_output=$(printf "%s" "$critique_data" | run_llm 30 -m "$PP_MODEL_CRITIQUE" -s "$critique_sys" 2>/dev/null)
          fi
          # Note: counted under worst-case-23 reservation at cycle start.

          # Apply verdicts + 1-retry auto-correction loop + streak tracking for escalation
          if [ -n "$critique_output" ]; then
            for ci in $(seq 0 $((PP_LENS_COUNT - 1))); do
              ci_id="${PP_LENS_IDS[$ci]}"
              verdict=$(echo "$critique_output" | grep -E "^lens${ci}:" | head -1)
              verdict_file="${HOME}/.claude/cache/cc-monitor-${session_id}-${ci_id}-verdict.txt"
              streak_file="${HOME}/.claude/cache/cc-monitor-${session_id}-${ci_id}-streak.txt"
              if [ -n "$verdict" ]; then
                echo "$verdict" > "$verdict_file"
                # FIX (review I1): DROP must be checked first (more specific) + word-boundary match
                if echo "$verdict" | grep -Eqi '\bDROP\b'; then
                  # Increment streak (drives escalation next cycle)
                  cur_streak=$(cat "$streak_file" 2>/dev/null || echo 0)
                  echo $((cur_streak + 1)) > "$streak_file"

                  # === 1-RETRY AUTO-CORRECTION ===
                  # Capture the prior failed output BEFORE we truncate it (the
                  # analyst subshell already wrote it to disk; $lens_suggestion
                  # itself isn't in scope here — it's a subshell-local variable).
                  # R2 ai-engineer #1: the most important behavior bug R1 didn't
                  # address — retry stdin was byte-identical to primary stdin and
                  # the failed observation never reached the retry model, making
                  # retry a lottery re-roll instead of corrective feedback.
                  _pp_lens_cache="${HOME}/.claude/cache/cc-monitor-${session_id}-${ci_id}.txt"
                  _pp_failed_output=""
                  [ -f "$_pp_lens_cache" ] && _pp_failed_output=$(head -1 "$_pp_lens_cache" 2>/dev/null)

                  # Atomic drop: truncate via tmp + rename so the display
                  # reader's `head -1` can't catch the file mid-truncate
                  # window (R2 H2 — same class R1 fixed for writes, missed
                  # for truncates).
                  : > "${_pp_lens_cache}.tmp" 2>/dev/null \
                    && mv "${_pp_lens_cache}.tmp" "$_pp_lens_cache" 2>/dev/null

                  drop_reason=$(echo "$verdict" | sed 's/^lens[0-9]*:[[:space:]]*//;s/^DROP[[:space:]]*-[[:space:]]*//')
                  # Re-derive this lens's prompt from the shared registry (lenses/*.json).
                  # Uses the SAME long-form focus as the primary path — no drift between
                  # primary and retry prompts.
                  rlens_group="${PP_LENS_IDS[$ci]}"
                  rlens_hats="${PP_LENS_HATS[$ci]}"
                  rlens_focus="${PP_LENS_FOCUS[$ci]}"

                  retry_sys=$(pp_render_prompt analyst-retry)

                  retry_result=""
                  if [ -n "$retry_sys" ]; then
                    metrics_increment_call retry "${PP_RETRY_MODEL:-$PP_MODEL}"
                    # Inject the failed output + drop reason as concrete
                    # counter-example into the retry input. The
                    # analyst-retry.md prompt references ${drop_reason} but
                    # without the original output the model has no contrast
                    # to learn from. (R2 ai-engineer #1.)
                    retry_input=$(printf 'PREVIOUS FAILED OBSERVATION:\n%s\n\nWHY IT WAS DROPPED:\n%s\n\n%s' \
                      "$_pp_failed_output" "$drop_reason" "$grounded")
                    retry_result=$(printf "%s" "$retry_input" | run_llm 45 -m "${PP_RETRY_MODEL:-$PP_MODEL}" -s "$retry_sys" 2>/dev/null)
                  fi
                  # Note: counted under worst-case-23 reservation at cycle start.

                  # Validate and accept the retry (loosened body min to 40 for retries)
                  if [ -n "$retry_result" ] && [ "$retry_result" != "SILENT" ] \
                      && echo "$retry_result" | head -1 | grep -Eq '^[A-Z]+: .{20,}\|\|\|.{40,}$'; then
                    # Atomic write — matches the primary path's pattern
                    # (Ralph round 2 BUG 3). Display reads via `head -1`
                    # can't race a half-written torn line.
                    _pp_retry_cache="${HOME}/.claude/cache/cc-monitor-${session_id}-${ci_id}.txt"
                    printf '%s\n' "$retry_result" > "${_pp_retry_cache}.tmp" 2>/dev/null \
                      && mv "${_pp_retry_cache}.tmp" "$_pp_retry_cache" 2>/dev/null
                    echo "${verdict} (retry accepted)" > "$verdict_file"
                  fi
                elif echo "$verdict" | grep -Eqi '\bPASS\b'; then
                  # PASS → reset drop streak
                  echo 0 > "$streak_file"
                fi
                # FIX (review I1): no verdict match (model omitted line or used unknown verb) → no streak update
              fi
            done
          fi
        fi

        # Bound history sizes after all writes finish
        tail -50 "$HIST_FILE_SESSION" > "${HIST_FILE_SESSION}.tmp" 2>/dev/null && mv "${HIST_FILE_SESSION}.tmp" "$HIST_FILE_SESSION"
        tail -100 "$HIST_FILE_PROJECT" > "${HIST_FILE_PROJECT}.tmp" 2>/dev/null && mv "${HIST_FILE_PROJECT}.tmp" "$HIST_FILE_PROJECT"
      fi  # grounded && llm available
      fi  # can_run — gates BOTH planner and analyst fan-out

      # Cycle cleanup (metrics flush + lock release) handled by the EXIT
      # trap above so SIGTERM mid-cycle can't lose data (review fix R2-M1).
      #
      # In normal operation the cycle is fire-and-forget (`&`) so the 2-second
      # statusline render isn't blocked by ~30-60s of LLM calls. In eval mode
      # (PP_EVAL_MODE=1) we run the cycle synchronously so observations are
      # available when we read the caches below.
    ) >/dev/null 2>&1 &
    _pp_cycle_pid=$!
    if [ "${PP_EVAL_MODE:-0}" = "1" ]; then
      wait "$_pp_cycle_pid" 2>/dev/null || true
    fi
  fi
fi

# === PP_EVAL_MODE — emit raw lens observations and exit ===
# Reads each lens's cache file written by the cycle above and emits one line
# per lens to stdout in the eval format: LENS_ID|||TOPIC|||HOOK|||BODY.
# TOPIC = the HAT prefix (e.g. ARCH), HOOK = the hook one-liner, BODY = the
# concrete next-step body. Lines for lenses with no observation (SILENT,
# malformed, or DROP-without-retry) are emitted with empty fields so the
# scorer can detect the absence. The normal statusline render is suppressed.
if [ "${PP_EVAL_MODE:-0}" = "1" ]; then
  for _ev_idx in $(seq 0 $((PP_LENS_COUNT - 1))); do
    _ev_id="${PP_LENS_IDS[$_ev_idx]}"
    _ev_cache="${PP_CACHE_DIR}/cc-monitor-${session_id}-${_ev_id}.txt"
    _ev_line=""
    if [ -f "$_ev_cache" ] && [ -s "$_ev_cache" ]; then
      _ev_line=$(head -1 "$_ev_cache" 2>/dev/null)
    fi
    if [ -n "$_ev_line" ] && printf '%s' "$_ev_line" | LC_ALL=C grep -Eq '^[A-Z]+: .{20,}\|\|\|.{40,}$'; then
      # Parse "HAT: hook|||body" into (HAT, hook, body)
      _ev_hat="${_ev_line%%:*}"
      _ev_rest="${_ev_line#*: }"
      _ev_hook="${_ev_rest%%|||*}"
      _ev_body="${_ev_rest#*|||}"
      printf '%s|||%s|||%s|||%s\n' "$_ev_id" "$_ev_hat" "$_ev_hook" "$_ev_body"
    else
      # Empty observation slot — emit blank fields so consumers see the lens
      # ran but produced nothing scorable (SILENT, dropped, no llm key, etc.)
      printf '%s|||||||\n' "$_ev_id"
    fi
  done
  exit 0
fi

# Resolve monitor: rotate through PP_LENS_COUNT lenses based on time slot (30s per lens)
# Plus 1 tip slot = (PP_LENS_COUNT + 1) total slots; with the default 7 lenses that's
# an 8-slot, 4-minute full cycle.
mon_topic=""
mon_body=""
_pp_slot_total=$((PP_LENS_COUNT + 1))
lens_slot=$(( ($(date +%s) / 30) % _pp_slot_total ))
if [ "$lens_slot" -lt "$PP_LENS_COUNT" ]; then
  PP_CACHE_DISPLAY="${PP_CACHE_DIR}/cc-monitor-${session_id}-${PP_LENS_IDS[$lens_slot]}.txt"
  if [ -f "$PP_CACHE_DISPLAY" ] && [ -s "$PP_CACHE_DISPLAY" ]; then
    mon=$(head -1 "$PP_CACHE_DISPLAY")
    if [ -n "$mon" ] && echo "$mon" | grep -q '|||'; then
      mon_topic="${mon%%|||*}"
      mon_body="${mon#*|||}"
    fi
  fi
fi

# === 2-line output: status + alternating advisor topic ===
# Line 1: ultra-compact status (~55-65 cells, fits narrow pane with notification margin)
# Line 2: tip topic (even minute) or monitor topic (odd minute) — alternates every 30s
#
# Per Claude Code docs: multi-line works with echo. Each line should be ≤80 cells
# to avoid the right-side notification area truncating with `…`.

# Aurora bullets — cycle through a small palette to give the info line a "living" feel
AURORA_PALETTE=("$TURQUOISE" "$LAVENDER" "$SKY" "$BRONZE")
aurora_hue="${AURORA_PALETTE[$tick]}"

# Display slot: 0..(PP_LENS_COUNT-1) = lens, PP_LENS_COUNT = tip slot.
# Already resolved above for monitor; use lens_slot so display stays coherent.
slot="$lens_slot"
# Map to 0 (tip) or non-zero (monitor) for downstream code that uses slot
if [ "$lens_slot" -eq "$PP_LENS_COUNT" ]; then slot=0; else slot=1; fi
info_topic_line=""
info_body_line=""

# Truncation budget per line (terminal will wrap, but Claude Code may truncate
# beyond ~140 cells with right-side notifications)
TOPIC_MAX=130
BODY_MAX=220

trim_to() {
  local s="$1" max="$2"
  if [ ${#s} -gt "$max" ]; then printf "%s…" "${s:0:$((max-1))}"; else printf "%s" "$s"; fi
}

# Two-tier output: topic on line 2, body on line 3. NO truncation — terminal wraps.
# Long topic or body will spill to additional visual rows below, but Claude Code sees
# them as 2 logical lines and renders them.
# Stronger validation — topic must be ≥20 chars to render (was 10).
# Prevents "▸ …" empty-display when LLM returns malformed output.
tip_valid=0
mon_valid=0
[ -n "$tip_topic" ] && [ ${#tip_topic} -ge 20 ] && tip_valid=1
[ -n "$mon_topic" ] && [ ${#mon_topic} -ge 20 ] && mon_valid=1

topic_line=""
body_line=""

if [ "$slot" -eq 0 ] && [ "$tip_valid" -eq 1 ]; then
  topic_line="${aurora_hue}▸${R}  ${BOLD}${CYAN_SOFT}${tip_topic}${R}"
  # Body intentionally NOT shown on terminal — goes to Claude via hook
  body_line=""
elif [ "$mon_valid" -eq 1 ]; then
  if [ $((tick % 2)) -eq 0 ]; then warn_hue=$SOFT_CRIMSON; else warn_hue=$SOFT_AMBER; fi
  topic_line="${warn_hue}⚠${R}  ${BOLD}${SOFT_CRIMSON}${mon_topic}${R}"
  # Body intentionally NOT shown on terminal — goes to Claude via hook
  body_line=""
elif [ "$tip_valid" -eq 1 ]; then
  topic_line="${aurora_hue}▸${R}  ${BOLD}${CYAN_SOFT}${tip_topic}${R}"
  body_line=""
fi

echo "$line"
[ -n "$topic_line" ] && echo "$topic_line"
[ -n "$body_line" ] && echo "$body_line"
exit 0
