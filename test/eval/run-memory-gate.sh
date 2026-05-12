#!/usr/bin/env bash
# Pair Polymath — memory subsystem eval gate (Task D.4 + v0.4 LLM-judge).
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
#   --dry-mode    Skip LLM calls. Validates the harness without spending
#                 API budget. Emits INFRA_PASS, exits 0.
#   --heuristic   Use the old regex-based scoring (citation-resolves =
#                 useful, citation-doesn't-resolve = hallucinated). Kept
#                 for fast local iteration; cheap but biased (see header).
#   --help        This message.
#
# DEFAULT MODE: LLM-judge (v0.4).
#   score.sh is invoked per cohort to call gpt-5 (or --cheap → gpt-5-mini)
#   on each observation+golden pair. Verdicts are aggregated to cohort-
#   level useful% / hallucinated% via per_lens counters in score-report.json.
#   Defenses against fixture-controlled prompt injection live in score.sh
#   (R1 code-reviewer H1). Budget: ~$0.50-$5 per gate run depending on
#   fixture count and scorer model. See docs/memory-architecture.md §8
#   for the heuristic-vs-LLM-judge tradeoff writeup.

set -e -u

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "$_dir/../.." && pwd)"
_run_eval="$_dir/run-eval.sh"
_score="$_dir/score.sh"

dry_mode=0
score_mode="llm"   # "llm" (default, v0.4) | "heuristic" (legacy, fast)
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-mode) dry_mode=1; shift ;;
    --no-dry|--no-dry-mode) dry_mode=0; shift ;;
    --heuristic) score_mode="heuristic"; shift ;;
    --llm-judge) score_mode="llm"; shift ;;
    --help|-h) sed -n '2,38p' "$0"; exit 0 ;;
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

# score_cohort_llm COHORT_DIR
# Stdout: "useful_pct\thallucinated_pct\tscored_count" (tab-separated).
#
# v0.4 LLM-judge path. score.sh already wrote score-report.json under the
# cohort's runs/<ts>/ when run_cohort() invoked it. Parse per_lens.useful
# and per_lens.hallucinated, aggregate to cohort-level percentages.
#
# `obvious` verdicts are excluded from BOTH numerator (useful) and the
# denominator's "harmful" side (hallucinated) — they're low-signal but
# not wrong. `missed_better` counts as not-useful (memory didn't help).
# `missing` (no observation emitted) doesn't count toward either bucket;
# it inflates the denominator only.
score_cohort_llm() {
  local cohort_dir="$1"
  # score.sh writes score-report.json next to the latest run-summary.json.
  # Find it: the cohort's runs-dir is cohort_dir itself, so the report is
  # under cohort_dir/<ts>/score-report.json. There's at most one ts per
  # cohort here.
  local report
  report=$(find "$cohort_dir" -name 'score-report.json' -type f 2>/dev/null | head -1)
  if [ -z "$report" ] || [ ! -f "$report" ]; then
    # No report (score.sh didn't run or no llm available) → caller decides.
    printf '0.00\t0.00\t0\n'
    return 0
  fi
  # Aggregate per_lens counters with jq. Sum useful across all lenses for
  # numerator. Denominator = useful + obvious + hallucinated + missed_better
  # + missing (exclude unscored — those are infra failures we don't penalize).
  local agg
  agg=$(jq -r '
    .per_lens
    | to_entries
    | map(.value) as $lenses
    | [($lenses | map(.useful // 0)         | add // 0),
       ($lenses | map(.obvious // 0)        | add // 0),
       ($lenses | map(.hallucinated // 0)   | add // 0),
       ($lenses | map(."missed-better" // 0)| add // 0),
       ($lenses | map(.missing // 0)        | add // 0)]
    | @tsv
  ' "$report" 2>/dev/null)
  if [ -z "$agg" ]; then
    printf '0.00\t0.00\t0\n'
    return 0
  fi
  local useful obvious halluc missed missing total upct hpct
  IFS=$'\t' read -r useful obvious halluc missed missing <<< "$agg"
  total=$(( useful + obvious + halluc + missed + missing ))
  if [ "$total" -le 0 ]; then
    printf '0.00\t0.00\t0\n'
    return 0
  fi
  upct=$(LC_ALL=C awk -v u="$useful" -v t="$total" 'BEGIN { printf "%.2f", (u/t)*100 }')
  hpct=$(LC_ALL=C awk -v h="$halluc" -v t="$total" 'BEGIN { printf "%.2f", (h/t)*100 }')
  printf '%s\t%s\t%s\n' "$upct" "$hpct" "$total"
}

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

if [ "$score_mode" = "llm" ]; then
  base_score=$(score_cohort_llm "$out_dir/baseline")
  cold_score=$(score_cohort_llm "$out_dir/cold")
  warm_score=$(score_cohort_llm "$out_dir/warm")
else
  base_score=$(score_cohort "$out_dir/baseline")
  cold_score=$(score_cohort "$out_dir/cold")
  warm_score=$(score_cohort "$out_dir/warm")
fi
base_useful=${base_score%%$'\t'*}
warm_useful=${warm_score%%$'\t'*}
base_halluc=$(printf '%s' "$base_score" | LC_ALL=C cut -f2)
warm_halluc=$(printf '%s' "$warm_score" | LC_ALL=C cut -f2)

base_p50=$(cohort_p50 "$out_dir/baseline" baseline)
warm_p50=$(cohort_p50 "$out_dir/warm" warm)
case "$base_p50" in ''|*[!0-9.]*) base_p50=0 ;; esac
case "$warm_p50" in ''|*[!0-9.]*) warm_p50=0 ;; esac

# Apply gate criteria. v0.4 R3.19: two paths to PASS, with three universal
# guards (yield floor, hallucinated non-regression, latency cap).
#
# Path A (useful-delta) — original v0.3 criterion: memory directly raises
#   useful%. Requires warm_useful >= base_useful + min_delta_pp.
#
# Path B (hallucinated-delta) — memory reduces fabrications. Requires
#   base_hallucinated - warm_hallucinated >= min_delta_pp AND
#   warm_useful >= base_useful (non-regression on useful).
#
# Either path triggers PASS, BUT only if all universal guards pass.
#
# UNIVERSAL #1 — yield floor (R3.19 ai-engineer review CRITICAL):
#   hallucinated% denominator includes `missing` (SILENT lenses). A warm
#   cohort that trivially makes all lenses silent gets hallucinated% = 0
#   for free, gaming Path B. Require warm to produce at least 50% of the
#   non-missing observations baseline produced (i.e. warm signal yield must
#   not collapse). Computed from per_lens counters in score-report.json.
# UNIVERSAL #2 — hallucinated non-regression.
# UNIVERSAL #3 — latency cap: warm_p50 <= base_p50 * 1.10.
#
# Statistical floor (R3.19 ai-engineer review CRITICAL):
#   At n=7 (one fixture × 7 lenses), one verdict flip = 14.3pp — below
#   judge variance. min_delta_pp ramps with sample size:
#     n  <  20  → 15pp
#     n  <  70  → 10pp
#     n >=  70  →  5pp
#   Auto-detected from baseline's total scored count.

verdict="PASS"
pass_path=""
failures=""

# Extract baseline's total scored from score-report (LLM mode) OR cycle
# count (heuristic mode) to size n.
_extract_baseline_n() {
  if [ "$score_mode" = "llm" ]; then
    local r
    r=$(find "$out_dir/baseline" -name 'score-report.json' -type f 2>/dev/null | head -1)
    [ -z "$r" ] && { printf '0'; return; }
    jq -r '
      .per_lens | to_entries | map(.value) as $L
      | ([$L[].useful, $L[].obvious, $L[]."missed-better", $L[].hallucinated, $L[].missing, $L[].unscored] | add // 0)
    ' "$r" 2>/dev/null || printf '0'
  else
    # Heuristic: third field of base_score is cycle_count
    printf '%s' "$base_score" | LC_ALL=C cut -f3
  fi
}
baseline_n=$(_extract_baseline_n)
case "$baseline_n" in ''|*[!0-9]*) baseline_n=0 ;; esac

# Dynamic min_delta_pp.
if [ "$baseline_n" -lt 20 ]; then
  min_delta_pp=15
elif [ "$baseline_n" -lt 70 ]; then
  min_delta_pp=10
else
  min_delta_pp=5
fi

# Yield-floor numerator: warm's useful + obvious counts (real outputs that
# aren't fabrications or absences). Pull from score-report when available.
_extract_yield_counts() {
  local cohort_dir="$1"
  if [ "$score_mode" = "llm" ]; then
    local r
    r=$(find "$cohort_dir" -name 'score-report.json' -type f 2>/dev/null | head -1)
    [ -z "$r" ] && { printf '0'; return; }
    jq -r '
      .per_lens | to_entries | map(.value) as $L
      | (([$L[].useful, $L[].obvious] | add) // 0)
    ' "$r" 2>/dev/null || printf '0'
  else
    # Heuristic doesn't distinguish obvious from useful; fall back to
    # useful_pct * cycle_count / 100.
    local pct n
    pct=$(printf '%s' "$1_score_proxy" | LC_ALL=C cut -f1)  # placeholder
    printf '0'
  fi
}
warm_yield=$(_extract_yield_counts "$out_dir/warm")
base_yield=$(_extract_yield_counts "$out_dir/baseline")
case "$warm_yield" in ''|*[!0-9]*) warm_yield=0 ;; esac
case "$base_yield" in ''|*[!0-9]*) base_yield=0 ;; esac

# INSUFFICIENT_DATA: if baseline produced < 3 scorable observations total,
# nothing the gate says is statistically meaningful.
if [ "$baseline_n" -lt 3 ]; then
  verdict="INSUFFICIENT_DATA"
  pass_path=""
  failures="${failures}baseline_n=${baseline_n}_below_3_scorable_obs; "
else
  # Path A check.
  path_a_ok=0
  LC_ALL=C awk -v wu="$warm_useful" -v bu="$base_useful" -v t="$min_delta_pp" \
      'BEGIN { exit (wu >= bu + t ? 0 : 1) }' \
    && path_a_ok=1

  # Path B check.
  path_b_ok=0
  if LC_ALL=C awk -v wh="$warm_halluc" -v bh="$base_halluc" -v t="$min_delta_pp" \
         'BEGIN { exit (bh - wh >= t ? 0 : 1) }' \
     && LC_ALL=C awk -v wu="$warm_useful" -v bu="$base_useful" \
          'BEGIN { exit (wu >= bu ? 0 : 1) }'; then
    path_b_ok=1
  fi

  if [ "$path_a_ok" = "1" ]; then
    pass_path="useful_delta"
  elif [ "$path_b_ok" = "1" ]; then
    pass_path="hallucinated_delta"
  else
    verdict="FAIL"
    pass_path=""
    failures="${failures}no_pass_path(useful_delta=warm:${warm_useful}-base:${base_useful}_below_${min_delta_pp}pp,hallucinated_delta=base:${base_halluc}-warm:${warm_halluc}_below_${min_delta_pp}pp_or_useful_regressed); "
  fi

  # UNIVERSAL #1: yield floor — warm must produce at least 50% of baseline's
  # non-missing observations. Protects against silence-gaming Path B
  # (R3.19 ai-engineer + code-reviewer C1).
  # Only applied in --llm-judge mode where the score-report distinguishes
  # useful+obvious from missing. Heuristic mode lacks this distinction.
  if [ "$score_mode" = "llm" ] && [ "$base_yield" -gt 0 ]; then
    _floor=$(( (base_yield + 1) / 2 ))   # ceil(base_yield / 2)
    if [ "$warm_yield" -lt "$_floor" ]; then
      verdict="FAIL"
      failures="${failures}yield_floor_violated(warm_yield=${warm_yield}_below_floor=${_floor}_of_base_yield=${base_yield}); "
    fi
  fi

  # UNIVERSAL #2: hallucinated must not regress.
  LC_ALL=C awk -v wh="$warm_halluc" -v bh="$base_halluc" 'BEGIN { exit (wh <= bh ? 0 : 1) }' \
    || { verdict="FAIL"; failures="${failures}hallucinated_regressed(warm=${warm_halluc},base=${base_halluc}); "; }

  # UNIVERSAL #3: latency must not blow up.
  if [ "$base_p50" != "0" ]; then
    LC_ALL=C awk -v wp="$warm_p50" -v bp="$base_p50" 'BEGIN { exit (wp <= bp * 1.10 ? 0 : 1) }' \
      || { verdict="FAIL"; failures="${failures}p50_regressed(warm=${warm_p50},base=${base_p50}); "; }
  fi

  # R3.19 code-reviewer C2: single point of pass_path invalidation. Resetting
  # at each gate is error-prone (a future-added universal check could forget
  # the reset); centralize here so verdict=FAIL ALWAYS implies pass_path="".
  [ "$verdict" = "FAIL" ] && pass_path=""
fi

_note=""
if [ "$score_mode" = "llm" ]; then
  _note="useful% / hallucinated% scored by gpt-5 LLM-judge via test/eval/score.sh against per-fixture goldens (test/eval/golden/). See docs/memory-architecture.md §8 for the methodology."
else
  _note="useful% / hallucinated% are HEURISTIC (non-empty + citation resolves) — kept available via --heuristic for fast local iteration. Default is --llm-judge (v0.4)."
fi
cat > "$out_dir/gate-summary.json" <<EOF
{
  "ts": "$ts",
  "dry_mode": 0,
  "score_mode": "$score_mode",
  "cohorts": ["baseline", "cold", "warm"],
  "verdict": "$verdict",
  "pass_path": "$pass_path",
  "min_delta_pp": $min_delta_pp,
  "baseline_n": $baseline_n,
  "baseline_yield": $base_yield,
  "warm_yield": $warm_yield,
  "baseline_useful_pct": $base_useful,
  "warm_useful_pct": $warm_useful,
  "baseline_hallucinated_pct": $base_halluc,
  "warm_hallucinated_pct": $warm_halluc,
  "baseline_p50_s": $base_p50,
  "warm_p50_s": $warm_p50,
  "failures": "$failures",
  "note": "$_note"
}
EOF

if [ "$verdict" = "PASS" ]; then
  printf '\nGate verdict: PASS via %s\n' "$pass_path"
  exit 0
fi
printf '\nGate verdict: FAIL\n'
exit 1
