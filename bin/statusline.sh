#!/usr/bin/env bash
# Claude Code statusLine — Magical Aladdin-palette edition
# Reads JSON from stdin, prints animated colored line.
# Designed for refreshInterval: 2 in settings.json.
# Spec: ~/.claude/specs/2026-05-11-claude-code-statusline-design.md

# Pair Polymath — load config + libs
_pp_bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_pp_bin_dir/../lib/config.sh"
# shellcheck disable=SC1091
. "$_pp_bin_dir/../lib/budget.sh"

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
    cache_key=$(echo "$repo_root" | shasum | cut -d' ' -f1)
    cache_file="/tmp/cc-pr-${cache_key}.cache"
    if [ ! -f "$cache_file" ] || [ $(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || echo 0))) -gt 600 ]; then
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
load_1m=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
if [ -n "$load_1m" ]; then
  load_int=$(awk -v l="$load_1m" 'BEGIN { printf "%d", l * 10 }')
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
TIP_LOCK="/tmp/cc-tips-fetch-${session_id}.lock"
mkdir -p "${HOME}/.claude/cache" 2>/dev/null

cache_age=$(($(date +%s) - $(stat -f %m "$TIP_CACHE" 2>/dev/null || echo 0)))
if [ ! -f "$TIP_CACHE" ] || [ "$cache_age" -gt 1800 ]; then
  lock_age=$(($(date +%s) - $(stat -f %m "$TIP_LOCK" 2>/dev/null || echo 0)))
  if [ ! -f "$TIP_LOCK" ] || [ "$lock_age" -gt 180 ]; then
    touch "$TIP_LOCK"
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
        digest=$(printf "USER PROJECT CONTEXT (from CLAUDE.md):\n%s\n\nRECENT WORK (last 5 commits):\n%s\n\nHN STORIES:\n%s\n\nARXIV PAPERS (cs.AI / cs.HC):\n%s" "$project_ctx" "$recent_commits" "$stories" "$arxiv_titles" | run_llm 40 -m gpt-5-mini -s \
"You're a personal learning editor for a developer/founder. You see their project context, recent work, plus today's HN stories and ArXiv papers. Write exactly 5 digests that THIS USER specifically should read or apply — bias hard toward relevance to their domain.

For each digest, pick the most relevant lens from the user's work domain:
UX, VISUAL, FRONTEND, BACKEND, ARCH, SECURITY, PERF, A11Y, BIZ, MARKET, PRODUCT, FINOPS, RESEARCH

Output format — one digest per line, EXACT shape:
LENS: punchy hook|||body explaining why it matters TO THIS USER + so-what + what to learn or do

Constraints:
- LENS: uppercase, one of the above
- Hook: ≤80 chars
- Body: 130-200 chars; the so-what + actionable; mention the user's domain when relevant
- Separator: exactly |||
- No emojis, quotes, numbering, preamble, markdown
- Skip generic content — every digest must connect to the user's actual work

Output 5 lines, nothing else." 2>/dev/null)

        if [ -n "$digest" ]; then
          echo "$digest" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*[-*0-9.)]*[[:space:]]*//' > "${TIP_CACHE}.tmp"
          [ -s "${TIP_CACHE}.tmp" ] && mv "${TIP_CACHE}.tmp" "$TIP_CACHE"
        fi
      elif [ -n "$stories" ]; then
        # Fallback: no llm CLI, just save raw titles
        echo "$stories" | sed 's/^- //; s/ — http.*$//' > "${TIP_CACHE}.tmp"
        [ -s "${TIP_CACHE}.tmp" ] && mv "${TIP_CACHE}.tmp" "$TIP_CACHE"
      fi
      rm -f "${TIP_CACHE}.tmp" "$TIP_LOCK"
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

# Per-lens cache files — populated by parallel run, read by display + hook
LENS_NAMES=("UX_DESIGN" "ENGINEERING" "SECURITY" "PERF_FINOPS" "PRODUCT_BIZ")

transcript_path=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

# Active/passive mode: detect idle terminal via transcript mtime.
# If > PP_IDLE_THRESHOLD_S since last activity → passive mode, skip LLM generation.
# Display cycle still shows last cached observations.
session_idle_s=0
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  session_idle_s=$(($(date +%s) - $(stat -f %m "$transcript_path" 2>/dev/null || echo $(date +%s))))
fi
is_active=1
[ "$session_idle_s" -gt "${PP_IDLE_THRESHOLD_S:-1800}" ] && is_active=0

# Check if parallel cycle is due
last_parallel=$(cat "$PP_LAST_PARALLEL" 2>/dev/null || echo 0)
parallel_age=$(($(date +%s) - last_parallel))

if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] \
    && [ "$is_active" -eq 1 ] \
    && [ "${PP_EXTERNAL_LLM:-1}" = "1" ] \
    && [ "$parallel_age" -gt "$PP_PARALLEL_INTERVAL_S" ]; then
  mon_lock_age=$(($(date +%s) - $(stat -f %m "$PP_LOCK" 2>/dev/null || echo 0)))
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
      # Single trap covering the cycle lock (now a dir) + the unified budget lock.
      trap '
        rmdir "$PP_LOCK" 2>/dev/null || rm -rf "$PP_LOCK" 2>/dev/null
        rmdir "${PP_BUDGET_FILE}.lock" 2>/dev/null
      ' EXIT INT TERM HUP

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
        test_age=$(($(date +%s) - $(stat -f %m "$test_cache_file" 2>/dev/null || echo 0)))
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
          repo_key=$(echo "$repo_root" | shasum 2>/dev/null | cut -d' ' -f1 | head -c 12)

          # PR list — fire-and-forget refresh, read latest cached
          pr_cache="${HOME}/.claude/cache/cc-pr-detail-${repo_key}.cache"
          pr_age=$(($(date +%s) - $(stat -f %m "$pr_cache" 2>/dev/null || echo 0)))
          if [ ! -f "$pr_cache" ] || [ "$pr_age" -gt 600 ]; then
            # FIX (advisor #3): atomic write — tmp file + mv
            ( cd "$repo_root" && gh pr list --limit 10 --json number,title,state,isDraft,statusCheckRollup 2>/dev/null \
              | jq -r '.[] | "PR#\(.number) [\(.state)\(if .isDraft then " DRAFT" else "" end)] \(.title) — CI: \([.statusCheckRollup[]?.state // "?"] | join(","))"' \
              > "${pr_cache}.tmp" 2>/dev/null && mv "${pr_cache}.tmp" "$pr_cache" ) &
          fi
          [ -f "$pr_cache" ] && gh_prs=$(cat "$pr_cache" 2>/dev/null | head -10)

          # CI run list — fire-and-forget refresh, 5min TTL
          ci_cache="${HOME}/.claude/cache/cc-ci-${repo_key}.cache"
          ci_age=$(($(date +%s) - $(stat -f %m "$ci_cache" 2>/dev/null || echo 0)))
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
      project_key=$(echo "$cwd" | shasum 2>/dev/null | cut -d' ' -f1 | head -c 12)
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
      can_run=0
      if budget_reserve 23; then
        can_run=1
      fi

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
        planner_prompt="Pick ONE file path whose contents would most clarify the current activity. The path MUST appear in the GIT STATUS, RECENTLY-CHANGED FILES, CWD LISTING, or RECENT TOOL CALLS sections — never invent. Prefer source files over build artifacts. If no file would help, output NONE. Output: just the path or NONE. No quotes, no explanation."
        candidate_file=$(printf "%s" "$planner_input" | run_llm 30 -m gpt-5-mini -s "$planner_prompt" 2>/dev/null | head -1 | tr -d "\"'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      fi

      # Read the chosen file (validated, 5KB cap)
      file_contents=""
      if [ -n "$candidate_file" ] && [ "$candidate_file" != "NONE" ] \
          && [ -n "$cwd" ] && [ "$cwd" != "-" ] && [ -d "$cwd" ]; then
        # Resolve to absolute path and enforce repo containment.
        # Reject any path outside cwd (no absolute-path fallback — closes a path-traversal vector).
        repo_real=$(cd "$cwd" 2>/dev/null && pwd -P)
        file_real=$(cd "$cwd" 2>/dev/null && realpath "$candidate_file" 2>/dev/null)
        if [ -n "$repo_real" ] && [ -n "$file_real" ]; then
          case "$file_real" in
            "$repo_real"/*)
              if [ -f "$file_real" ] && [ -r "$file_real" ]; then
                file_contents=$(head -c 5000 "$file_real" 2>/dev/null)
              fi
              ;;
            *)
              candidate_file="NONE"  # silently reject paths outside repo
              ;;
          esac
        else
          candidate_file="NONE"
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

      if [ -n "$grounded" ] && command -v llm >/dev/null 2>&1; then
        # === PARALLEL 5-AGENT FAN-OUT ===
        # Run all 5 lenses in parallel subshells. Each writes to its own cache.
        for lens_idx in 0 1 2 3 4 5 6; do
          case $lens_idx in
            0) lens_group="UX_DESIGN"; lens_hats="UX, VISUAL, A11Y"; lens_focus="user experience, visual hierarchy, accessibility, micro-interactions, information architecture, design system consistency" ;;
            1) lens_group="ENGINEERING"; lens_hats="ARCH, FRONTEND, BACKEND, DEVOPS"; lens_focus="code structure, coupling, test coverage, build/deploy, refactor opportunities, technical debt" ;;
            2) lens_group="SECURITY"; lens_hats="SECURITY"; lens_focus="secrets in commits, untracked sensitive files, attack surface, auth/authz, data exposure, dependency vulnerabilities" ;;
            3) lens_group="PERF_FINOPS"; lens_hats="PERF, FINOPS"; lens_focus="latency hot paths, bundle size, cache hit rate, model/API cost, idle resources, scaling limits" ;;
            4) lens_group="PRODUCT_BIZ"; lens_hats="PRODUCT, BIZ, MARKET, RESEARCH"; lens_focus="user value gaps, scope drift, pricing/monetization angle, competitor positioning, research validity, missing product surface" ;;
            5) lens_group="STRATEGIC_FOUNDER"; lens_hats="STRATEGY, FOCUS, OPPORTUNITY"; lens_focus="opportunity cost of current work, what NOT to build, competitive positioning, 80/20 focus discipline, time-to-revenue, kill criteria for stalled efforts" ;;
            6) lens_group="COGNITIVE_FLOW"; lens_hats="FLOW, FOCUS, REST"; lens_focus="cognitive load signals, context-switch cost, deep-work windows, break timing, burnout markers, decision fatigue, working-memory overload from too many open threads" ;;
          esac
          PP_CACHE_LENS="${PP_CACHE_DIR}/cc-monitor-${session_id}-lens${lens_idx}.txt"

          # === Escalation check: if this lens has 3+ consecutive drops, escalate to deep mode ===
          # Deep mode = extra lens-specific evidence-gathering (mini-planner picks files + greps)
          # before main analyst runs. Resets after one PASS.
          lens_streak_file="${HOME}/.claude/cache/cc-monitor-${session_id}-lens${lens_idx}-streak.txt"
          lens_streak=$(cat "$lens_streak_file" 2>/dev/null || echo 0)
          is_escalated=0
          [ "$lens_streak" -ge 3 ] && [ "${PP_ENABLE_ESCALATION:-1}" = "1" ] && is_escalated=1

          # Rotate the "deep" slot (gpt-5.5) AND the "wildcard" slot (broad allowance)
          # Both rotate every cycle through 5 positions. Offset wildcard so they don't
          # always coincide (deep stays focused; wildcard is the broader one).
          # FIX (review): rotate through all 7 lenses, not 5
          deep_slot=$(( ($(date +%s) / PP_PARALLEL_INTERVAL_S) % 7 ))
          wildcard_slot=$(( (deep_slot + 2) % 7 ))
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
              inv_sys="You are pre-investigating for the ${lens_group} lens focused on ${lens_focus}. Given the grounded facts below, identify (a) ONE additional file path from CWD/git status whose contents would be most revealing for this lens, OR (b) ONE grep pattern that would surface evidence specific to this lens. Output exactly two lines: FILE: <path or NONE>  and  GREP: <pattern or NONE>. No preamble."
              inv_output=$(printf "%s" "$grounded" | run_llm 25 -m gpt-5-mini -s "$inv_sys" 2>/dev/null)
              # Note: counted under worst-case-23 reservation at cycle start.

              if [ -n "$inv_output" ]; then
                inv_file=$(echo "$inv_output" | grep '^FILE:' | head -1 | sed 's/^FILE:[[:space:]]*//')
                inv_grep=$(echo "$inv_output" | grep '^GREP:' | head -1 | sed 's/^GREP:[[:space:]]*//')

                # File read with containment
                if [ -n "$inv_file" ] && [ "$inv_file" != "NONE" ] && [ -d "$cwd" ]; then
                  inv_repo_real=$(cd "$cwd" 2>/dev/null && pwd -P)
                  inv_file_real=$(cd "$cwd" 2>/dev/null && realpath "$inv_file" 2>/dev/null)
                  case "$inv_file_real" in
                    "$inv_repo_real"/*)
                      [ -f "$inv_file_real" ] && [ -r "$inv_file_real" ] && \
                        lens_evidence="ESCALATED FILE READ ($inv_file):
$(head -c 3000 "$inv_file_real" 2>/dev/null)

" ;;
                  esac
                fi

                # Grep results — validated for safety + bounded
                # FIX (review C4): reject overly broad/short patterns to prevent ReDoS + tree-walk
                if [ -n "$inv_grep" ] && [ "$inv_grep" != "NONE" ] && [ -d "$cwd" ] \
                    && [ ${#inv_grep} -ge 4 ] && [ ${#inv_grep} -le 100 ] \
                    && echo "$inv_grep" | grep -Eq '[a-zA-Z0-9_]{3,}' \
                    && ! echo "$inv_grep" | grep -qE '^(\.|\.\*|\^|\$|\^.\*\$)$'; then
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

            analyst_prompt="You are the ${lens_group} agent in a 7-agent parallel advisory team. THIS CYCLE you specialize in ${lens_focus}. Pick a HAT from ${lens_hats}. RELEVANCE MODE: ${relevance_directive} SENIOR-ENGINEER CHALLENGE MODE: Treat the transcript like a confident junior's report. When the assistant or user claims something is 'done', 'fixed', 'working', or 'verified', do NOT take it at face value. Check the evidence (file contents, git status, test cache, CI runs). If the claim lacks supporting evidence, your observation should be: the claimed state is unverified — here's the test or check to prove it. Challenge confident-sounding statements; do not flatter the work. PRIORITY EVIDENCE: If LAST TEST/LINT RUN shows ERROR: true, prioritize that failure as the observation and cite the specific test name from OUTPUT if visible. If OPEN PRS shows a draft or failing CI for the active branch, or RECENT CI RUNS shows a failing or in-progress workflow, surface that observation specifically — it outranks abstract concerns. You are a senior technical consultant — fluent as product designer, engineer, architect, founder, and cognitive scientist — pair-programming with Claude Code. You receive GROUNDED FACTS plus PREVIOUS OBSERVATIONS and transcript tail. Surface ONE specific actionable observation that the user could be missing within YOUR domain for this cycle. FRAMEWORKS (cite by name ONLY when one clearly fits the situation — never force-fit, never use more than one per observation): Cynefin (simple/complicated/complex/chaotic categorization), Theory of Constraints (find/exploit the bottleneck), First Principles (decompose to fundamentals), Chesterton's Fence (do not remove what you do not understand), Premortem (imagine future failure, work backward), Hofstadter's Law (tasks take longer than expected), Goodhart's Law (a metric that becomes the target ceases to be useful), Conway's Law (system structure mirrors org structure), Postel's Law (be liberal in what you accept, conservative in what you emit). CRITICAL RULES: Only cite paths or symbols that appear in the provided sections. NEVER invent. When citing a function/class name in your observation, that name MUST appear in SYMBOL REFERENCE COUNTS. If it does not appear, mark with [unverified] OR pick a different observation. If FILE READ section has contents, prefer observations referencing those contents. Do NOT repeat anything in PREVIOUS OBSERVATIONS. Pick a different angle. If inferring without ground truth, tag [inferred] in the body. Skip the obvious. Look for blind spots. OUTPUT FORMAT: single line, exact shape: HAT: hook|||body where HAT is 2-12 chars uppercase, hook is 40-70 chars, body is 80-180 chars with concrete next step ending in a verb like Fix Refactor Extract Add Move Verify Cap Cite Schedule or Defer. No emojis, quotes, markdown, numbering, or preamble. If nothing notable: output SILENT."
            lens_suggestion=$(printf "%s" "$lens_grounded" | run_llm 60 -m "$agent_model" -s "$analyst_prompt" 2>/dev/null)

            # Validate + write per-lens cache
            if [ -n "$lens_suggestion" ] && [ "$lens_suggestion" != "SILENT" ]; then
              if echo "$lens_suggestion" | head -1 | grep -Eq '^[A-Z]+: .{20,}\|\|\|.{40,}$'; then
                echo "$lens_suggestion" > "$PP_CACHE_LENS"
                # Append to histories (session + project) — appends are atomic on POSIX
                echo "$lens_suggestion" >> "$HIST_FILE_SESSION"
                echo "$lens_suggestion" >> "$HIST_FILE_PROJECT"
              fi
              # malformed → keep previous cache content untouched
            fi
            # SILENT → don't overwrite (keep previous valid observation)
          ) &
        done
        wait  # all 7 analysts to complete

        # === SELF-CRITIQUE PASS (gpt-5, ~$0.025/call) ===
        # Reviews all 7 observations against grounded facts; drops weak/hallucinated/redundant ones.
        # FIX (advisor #1): truncate per-lens output to bound token cost on big observations.
        critique_input=""
        for ci in 0 1 2 3 4 5 6; do
          cf="${HOME}/.claude/cache/cc-monitor-${session_id}-lens${ci}.txt"
          if [ -f "$cf" ] && [ -s "$cf" ]; then
            obs_short=$(head -1 "$cf" | head -c 500)   # cap each lens at 500 chars
            critique_input="${critique_input}lens${ci}: ${obs_short}"$'\n'
          fi
        done

        if [ -n "$critique_input" ]; then
          critique_sys="You are reviewing 7 advisor observations against grounded facts. For EACH lens line, decide PASS or DROP. DROP if: hallucinated (cites file/symbol not in grounded facts), stale (referring to fixed issues), redundant (same angle as another lens), low-value (vague, generic, no concrete action). PASS if: specific, verifiable, actionable, technically grounded. Output format: ONE line per lens, exactly: lensN: PASS  or  lensN: DROP — REASON  (where REASON is one short phrase explaining why). No preamble."
          critique_data="GROUNDED FACTS:
${grounded:0:3000}

OBSERVATIONS TO JUDGE:
$critique_input"
          critique_output=$(printf "%s" "$critique_data" | run_llm 30 -m "$PP_MODEL_CRITIQUE" -s "$critique_sys" 2>/dev/null)
          # Note: counted under worst-case-23 reservation at cycle start.

          # Apply verdicts + 1-retry auto-correction loop + streak tracking for escalation
          if [ -n "$critique_output" ]; then
            for ci in 0 1 2 3 4 5 6; do
              verdict=$(echo "$critique_output" | grep -E "^lens${ci}:" | head -1)
              verdict_file="${HOME}/.claude/cache/cc-monitor-${session_id}-lens${ci}-verdict.txt"
              streak_file="${HOME}/.claude/cache/cc-monitor-${session_id}-lens${ci}-streak.txt"
              if [ -n "$verdict" ]; then
                echo "$verdict" > "$verdict_file"
                # FIX (review I1): DROP must be checked first (more specific) + word-boundary match
                if echo "$verdict" | grep -Eqi '\bDROP\b'; then
                  # Increment streak (drives escalation next cycle)
                  cur_streak=$(cat "$streak_file" 2>/dev/null || echo 0)
                  echo $((cur_streak + 1)) > "$streak_file"

                  # Empty the cache (drop)
                  : > "${HOME}/.claude/cache/cc-monitor-${session_id}-lens${ci}.txt"

                  # === 1-RETRY AUTO-CORRECTION ===
                  # Re-run analyst with critique reason as feedback. One shot.
                  drop_reason=$(echo "$verdict" | sed 's/^lens[0-9]*:[[:space:]]*//;s/^DROP[[:space:]]*-[[:space:]]*//')
                  # Re-derive this lens's prompt from same case mapping
                  case $ci in
                    0) rlens_group="UX_DESIGN"; rlens_hats="UX, VISUAL, A11Y"; rlens_focus="user experience, visual hierarchy, accessibility, micro-interactions" ;;
                    1) rlens_group="ENGINEERING"; rlens_hats="ARCH, FRONTEND, BACKEND, DEVOPS"; rlens_focus="code structure, coupling, test coverage, refactor opportunities" ;;
                    2) rlens_group="SECURITY"; rlens_hats="SECURITY"; rlens_focus="secrets, untracked sensitive files, attack surface, auth/authz" ;;
                    3) rlens_group="PERF_FINOPS"; rlens_hats="PERF, FINOPS"; rlens_focus="latency, bundle size, cache hits, API cost" ;;
                    4) rlens_group="PRODUCT_BIZ"; rlens_hats="PRODUCT, BIZ, MARKET, RESEARCH"; rlens_focus="user value gaps, scope drift, monetization, research validity" ;;
                    5) rlens_group="STRATEGIC_FOUNDER"; rlens_hats="STRATEGY, FOCUS, OPPORTUNITY"; rlens_focus="opportunity cost, what NOT to build, 80/20 focus, kill criteria" ;;
                    6) rlens_group="COGNITIVE_FLOW"; rlens_hats="FLOW, FOCUS, REST"; rlens_focus="cognitive load, context-switch cost, deep-work windows, burnout markers" ;;
                  esac

                  retry_sys="You are the ${rlens_group} lens. Your previous observation was DROPPED by the critique pass with reason: ${drop_reason}. Try a DIFFERENT angle, file, or pattern. Same constraints: pick a HAT from ${rlens_hats}, focus on ${rlens_focus}, output exactly HAT: hook|||body (hook 40-70 chars, body 80-180 chars ending in a verb). Only cite paths/symbols visible in the grounded facts. If you still cannot find a valid different observation, output SILENT."

                  retry_result=$(printf "%s" "$grounded" | run_llm 45 -m "$PP_MODEL" -s "$retry_sys" 2>/dev/null)
                  # Note: counted under worst-case-23 reservation at cycle start.

                  # Validate and accept the retry (loosened body min to 40 for retries)
                  if [ -n "$retry_result" ] && [ "$retry_result" != "SILENT" ] \
                      && echo "$retry_result" | head -1 | grep -Eq '^[A-Z]+: .{20,}\|\|\|.{40,}$'; then
                    echo "$retry_result" > "${HOME}/.claude/cache/cc-monitor-${session_id}-lens${ci}.txt"
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
      rmdir "$PP_LOCK" 2>/dev/null || rm -rf "$PP_LOCK" 2>/dev/null
    ) >/dev/null 2>&1 &
  fi
fi

# Resolve monitor: rotate through 7 lenses based on time slot (30s per lens)
# Plus 1 tip slot = 8 total slots, 4-min full cycle
mon_topic=""
mon_body=""
lens_slot=$(( ($(date +%s) / 30) % 8 ))
if [ "$lens_slot" -lt 7 ]; then
  PP_CACHE_DISPLAY="${PP_CACHE_DIR}/cc-monitor-${session_id}-lens${lens_slot}.txt"
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

# Display slot: 0=lens0..4=lens4, 5=tip. Already resolved above for monitor.
# Use lens_slot for the same rotation so display stays coherent.
slot="$lens_slot"
# Map to 0 (tip) or non-zero (monitor) for downstream code that uses slot
if [ "$lens_slot" -eq 7 ]; then slot=0; else slot=1; fi
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
