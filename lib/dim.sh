#!/usr/bin/env bash
# v0.5.3 — Developer Insights Module control plane.
#
# Owns: gate evaluator, state machine, state-file I/O.
# Reads: oar-labeled.jsonl (via lib/dim-stats.sh aggregator).
# Writes: dim-state.${sha8}.jsonl, dim-gate-last-eval.${sha8}.jsonl,
#         dim-last-eval-epoch.${sha8}.txt.
#
# All state files are per-project (sharded by project_root_sha8) to prevent
# one project's OAR accumulation from auto-activating DIM for another.
# Bash 3.2-portable: no mapfile, no ${var,,}, no flock.

[ "${_PP_DIM_SOURCED:-0}" = "1" ] && return 0

export LC_ALL=C
_PP_DIM_SOURCED=1

# Lazy-load stats helpers
if [ "${_PP_DIM_STATS_SOURCED:-0}" != "1" ]; then
  _pp_dim_root="${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  # shellcheck disable=SC1091
  . "$_pp_dim_root/lib/dim-stats.sh"
fi

# Gate parameters (locked by spec).
PP_DIM_ALPHA="${PP_DIM_ALPHA:-0.05}"
PP_DIM_TARGET_LCB="${PP_DIM_TARGET_LCB:-0.05}"
PP_DIM_MIN_LENSES="${PP_DIM_MIN_LENSES:-3}"
PP_DIM_MIN_N="${PP_DIM_MIN_N:-250}"
PP_DIM_MIN_DISTINCT_DATES="${PP_DIM_MIN_DISTINCT_DATES:-5}"
PP_DIM_MIN_CALENDAR_DAYS="${PP_DIM_MIN_CALENDAR_DAYS:-7}"
PP_DIM_HOLDOUT_VALIDATION_DAYS="${PP_DIM_HOLDOUT_VALIDATION_DAYS:-7}"
PP_DIM_QUARANTINE_RECOVERY_DAYS="${PP_DIM_QUARANTINE_RECOVERY_DAYS:-14}"

# pp_dim_state_file_path SHA8 → /path/to/dim-state.<sha8>.jsonl
pp_dim_state_file_path() {
  echo "${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/dim-state.${1:-default}.jsonl"
}

# pp_dim_last_eval_path SHA8 → /path/to/dim-last-eval-epoch.<sha8>.txt
pp_dim_last_eval_path() {
  echo "${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/dim-last-eval-epoch.${1:-default}.txt"
}

# pp_dim_gate_eval_path SHA8 → /path/to/dim-gate-last-eval.<sha8>.jsonl
pp_dim_gate_eval_path() {
  echo "${PP_CACHE_DIR:-${CLAUDE_DIR:-$HOME/.claude}/cache}/dim-gate-last-eval.${1:-default}.jsonl"
}
