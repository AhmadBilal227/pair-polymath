#!/usr/bin/env bash
# Pair Polymath — memory subsystem eval gate (Task D.4 + R2 F2).
#
# Runs the existing eval suite (test/eval/run-eval.sh) three times and
# compares cycle latency + useful% + hallucinated% across the three runs:
#
#   1. PP_MEMORY_ENABLE=0           (baseline / off-mode)
#   2. PP_MEMORY_ENABLE=1, fresh DB (cold)
#   3. PP_MEMORY_ENABLE=1, pre-populated DB (warm)
#
# PASS criteria (non-dry only):
#   - warm useful% >= baseline useful% + 5pp
#   - warm hallucinated% <= baseline hallucinated%
#   - warm cycle latency p50 <= baseline p50 * 1.10
#
# FAIL on any violation (script exits non-zero).
#
# Flags:
#   --dry-mode   Skip LLM calls. Validates the harness without spending API
#                budget. Emits INFRA_PASS, exits 0.
#   --help       This message.
#
# HEURISTIC LIMITATION (R2 F2):
#   `useful%` and `hallucinated%` here are computed from per-cohort cycle
#   output files using a regex heuristic, NOT an LLM-as-judge. A cycle's
#   output is "useful" iff it is non-trivial (>100 chars) AND contains at
#   least one citation that resolves to a real path. It is "hallucinated"
#   iff it contains a citation that does NOT resolve to a real path. This
#   catches obvious wins/losses but cannot distinguish a useful-but-vague
#   observation from a useless-but-precise one. The LLM-judge replacement
#   is v0.4 — see docs/memory-architecture.md §8.

set -e -u

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "$_dir/../.." && pwd)"
_run_eval="$_dir/run-eval.sh"
_score="$_dir/score.sh"

dry_mode=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-mode) dry_mode=1; shift ;;
    --no-dry|--no-dry-mode) dry_mode=0; shift ;;
    --help|-h) sed -n '2,33p' "$0"; exit 0 ;;
    *) printf 'run-memory-gate.sh: unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Output dir for this gate run.
ts=$(date -u +%Y%m%dT%H%M%SZ)
out_dir="$_dir/runs/memory-gate-$ts"
mkdir -p "$out_dir"

printf 'Pair Polymath — memory eval gate\n'
printf '  Output: %s\n' "$out_dir"
printf '  Dry mode: %s\n\n' "$dry_mode"

# Pre-flight: the harness must exist.
if [ ! -x "$_run_eval" ]; then
  printf 'gate: run-eval.sh missing or not executable: %s\n' "$_run_eval" >&2
  exit 1
fi

# Helper: run one cohort of the gate and capture per-cycle latency.
# Args: $1=label $2..=env assignments for the inner shell.
run_cohort() {
  local label="$1"; shift
  local cohort_dir="$out_dir/$label"
  mkdir -p "$cohort_dir"
  local start_s end_s
  start_s=$(date +%s)
  if [ "$dry_mode" = "1" ]; then
    printf 'cohort=%s\n' "$label" > "$cohort_dir/cohort.env"
    for kv in "$@"; do
      printf '%s\n' "$kv" >> "$cohort_dir/cohort.env"
    done
    printf '{"label":"%s","stubbed":true}\n' "$label" > "$cohort_dir/stub.json"
  else
    env "$@" "$_run_eval" --runs-dir "$cohort_dir" \
      > "$cohort_dir/stdout.log" 2>&1 || true
    if [ -x "$_score" ]; then
      "$_score" --runs-dir "$cohort_dir" > "$cohort_dir/score.txt" 2>/dev/null || true
    fi
  fi
  end_s=$(date +%s)
  local elapsed=$(( end_s - start_s ))
  printf '  %s: %ss\n' "$label" "$elapsed" >&2
  printf '%s\t%s\n' "$label" "$elapsed" >> "$out_dir/timings.tsv"
}

# === Cohort 1: baseline / memory off ===
printf 'Running cohort 1 (memory OFF, baseline)...\n' >&2
run_cohort baseline PP_MEMORY_ENABLE=0

# === Cohort 2: memory on, cold DB (fresh project_dir) ===
printf 'Running cohort 2 (memory ON, cold)...\n' >&2
cold_mem_dir=$(mktemp -d "$out_dir/cold-mem.XXXXXX")
run_cohort cold PP_MEMORY_ENABLE=1 PP_MEMORY_DIR="$cold_mem_dir"

# === Cohort 3: memory on, warm DB (recycled cold dir) ===
printf 'Running cohort 3 (memory ON, warm)...\n' >&2
run_cohort warm PP_MEMORY_ENABLE=1 PP_MEMORY_DIR="$cold_mem_dir"

# === Summary ===
printf '\nCohort timings (label\tseconds):\n'
cat "$out_dir/timings.tsv"

# In dry mode we emit INFRA_PASS without computing useful%/hallucinated%
# (no cycle outputs exist to score).
if [ "$dry_mode" = "1" ]; then
  cat > "$out_dir/gate-summary.json" <<EOF
{
  "ts": "$ts",
  "dry_mode": 1,
  "cohorts": ["baseline", "cold", "warm"],
  "verdict": "INFRA_PASS",
  "note": "Dry-mode run — no LLM calls fired, no useful%/hallucinated% metrics computed. Re-run with --no-dry to get a real PASS/FAIL verdict."
}
EOF
  printf '\nGate (dry-mode): INFRA_PASS\n'
  exit 0
fi

# === Non-dry path: compute useful% / hallucinated% / latency ===
#
# Heuristic, by design (see header). Walks each cohort's cycle-output files,
# matches the citation regex against grep, and checks whether each match
# resolves to a real path under the cohort's cwd. If $_score produced a JSON
# stats file, we read p50/p99 from it; otherwise we fall back to scanning
# the run logs.
#
# Citation regex: a token that looks like `path/to/file.ext:N` where ext is
# one of the common source extensions we'd cite. Anchored to word-boundary
# behavior via grep -E.
_citation_re='[A-Za-z0-9_./-]+\.(ts|js|tsx|jsx|py|go|rs|java|sh|md):[0-9]+'

# score_cohort COHORT_DIR
# Stdout: "useful_pct\thallucinated_pct\tcycle_count" (tab-separated).
score_cohort() {
  local cohort_dir="$1"
  local useful=0 halluc=0 total=0
  # Each "cycle" is one output file under cohort_dir. Pick a generic glob
  # — run-eval.sh writes cycle-{N}.txt or similar; we accept any .txt or
  # .log files that aren't the stdout aggregate.
  local f size path
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "stdout.log" ] && continue
    size=$(LC_ALL=C wc -c < "$f" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    total=$((total + 1))
    [ "$size" -le 100 ] && continue   # too short → not useful, not halluc
    # Extract citation tokens; for each, test if path resolves under repo_root.
    local cite cite_path cite_ok=0 cite_bad=0
    while IFS= read -r cite; do
      [ -z "$cite" ] && continue
      cite_path="${cite%%:*}"
      if [ -e "$_repo_root/$cite_path" ] || [ -e "$cite_path" ]; then
        cite_ok=1
      else
        cite_bad=1
      fi
    done < <(LC_ALL=C grep -Eo "$_citation_re" "$f" 2>/dev/null | LC_ALL=C sort -u)
    [ "$cite_ok" = "1" ] && useful=$((useful + 1))
    [ "$cite_bad" = "1" ] && halluc=$((halluc + 1))
  done < <(find "$cohort_dir" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.json' \) 2>/dev/null)
  local upct=0 hpct=0
  if [ "$total" -gt 0 ]; then
    upct=$(LC_ALL=C awk -v u="$useful" -v t="$total" 'BEGIN { printf "%.2f", (u/t)*100 }')
    hpct=$(LC_ALL=C awk -v h="$halluc" -v t="$total" 'BEGIN { printf "%.2f", (h/t)*100 }')
  fi
  printf '%s\t%s\t%s\n' "$upct" "$hpct" "$total"
}

# Latency p50: read from score.txt if score.sh wrote one, else use the
# overall cohort wallclock as a proxy (single sample, so p50=p99=elapsed).
cohort_p50() {
  local cohort_dir="$1" label="$2"
  if [ -f "$cohort_dir/score.txt" ]; then
    local p50
    p50=$(LC_ALL=C grep -E '^p50' "$cohort_dir/score.txt" 2>/dev/null | head -1 | awk '{print $2}')
    if [ -n "$p50" ]; then printf '%s' "$p50"; return; fi
  fi
  LC_ALL=C awk -v lbl="$label" '$1 == lbl { print $2; exit }' "$out_dir/timings.tsv"
}

base_score=$(score_cohort "$out_dir/baseline")
cold_score=$(score_cohort "$out_dir/cold")
warm_score=$(score_cohort "$out_dir/warm")
base_useful=${base_score%%$'\t'*}
warm_useful=${warm_score%%$'\t'*}
base_halluc=$(printf '%s' "$base_score" | LC_ALL=C cut -f2)
warm_halluc=$(printf '%s' "$warm_score" | LC_ALL=C cut -f2)

base_p50=$(cohort_p50 "$out_dir/baseline" baseline)
warm_p50=$(cohort_p50 "$out_dir/warm" warm)
case "$base_p50" in ''|*[!0-9.]*) base_p50=0 ;; esac
case "$warm_p50" in ''|*[!0-9.]*) warm_p50=0 ;; esac

# Apply gate criteria.
verdict="PASS"
failures=""
LC_ALL=C awk -v wu="$warm_useful" -v bu="$base_useful" 'BEGIN { exit (wu >= bu + 5 ? 0 : 1) }' \
  || { verdict="FAIL"; failures="${failures}useful_delta_below_5pp(warm=${warm_useful},base=${base_useful}); "; }
LC_ALL=C awk -v wh="$warm_halluc" -v bh="$base_halluc" 'BEGIN { exit (wh <= bh ? 0 : 1) }' \
  || { verdict="FAIL"; failures="${failures}hallucinated_regressed(warm=${warm_halluc},base=${base_halluc}); "; }
if [ "$base_p50" != "0" ]; then
  LC_ALL=C awk -v wp="$warm_p50" -v bp="$base_p50" 'BEGIN { exit (wp <= bp * 1.10 ? 0 : 1) }' \
    || { verdict="FAIL"; failures="${failures}p50_regressed(warm=${warm_p50},base=${base_p50}); "; }
fi

cat > "$out_dir/gate-summary.json" <<EOF
{
  "ts": "$ts",
  "dry_mode": 0,
  "cohorts": ["baseline", "cold", "warm"],
  "verdict": "$verdict",
  "baseline_useful_pct": $base_useful,
  "warm_useful_pct": $warm_useful,
  "baseline_hallucinated_pct": $base_halluc,
  "warm_hallucinated_pct": $warm_halluc,
  "baseline_p50_s": $base_p50,
  "warm_p50_s": $warm_p50,
  "failures": "$failures",
  "note": "useful% / hallucinated% are HEURISTIC (non-empty + citation resolves). LLM-judge replacement is v0.4 — see docs/memory-architecture.md §8."
}
EOF

printf '\nGate verdict: %s\n' "$verdict"
[ "$verdict" = "PASS" ] && exit 0
exit 1
