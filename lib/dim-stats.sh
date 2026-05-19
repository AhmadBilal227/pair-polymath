#!/usr/bin/env bash
# v0.5.3 — Developer Insights Module statistical helpers.
#
# Pure-math primitives consumed by lib/dim.sh. No I/O, no env reads beyond
# the salt path. Bash 3.2-portable: no mapfile, no ${var,,}, no local -n.
# LC_ALL=C enforced at file top to neutralize locale-dependent awk printf
# behavior on the Wilson / anytime-CS calculations.

[ "${_PP_DIM_STATS_SOURCED:-0}" = "1" ] && return 0

export LC_ALL=C
_PP_DIM_STATS_SOURCED=1

# pp_dim_stats_lcb_anytime SUCCESSES TRIALS ALPHA
# Time-uniform Wilson-style lower confidence bound (Howard et al. 2021).
# Holds simultaneously for all n; safe to peek at arbitrary times.
# Echoes the bound as a float (locale-independent).
pp_dim_stats_lcb_anytime() {
  local s="${1:-0}" n="${2:-0}" alpha="${3:-0.05}"
  LC_ALL=C awk -v s="$s" -v n="$n" -v alpha="$alpha" 'BEGIN {
    if (n + 0 <= 0) { printf "0.0000\n"; exit }
    # Alpha must be in (0, 1) — otherwise the log(2/alpha) term is
    # undefined (alpha<=0) or non-positive (alpha>=2), which silently
    # produces an over-confident LCB. Refuse with a conservative 0.
    if (alpha + 0 <= 0 || alpha + 0 >= 1) { printf "0.0000\n"; exit }
    if (s + 0 < 0)  s = 0
    if (s + 0 > n)  s = n
    n2 = (2.0 * n < 4 ? 4 : 2.0 * n)
    psi2 = log(log(n2)) + log(2.0 / alpha)
    if (psi2 < 0) psi2 = 0
    psi = sqrt(psi2)
    denom = n + psi2
    center = (s + 0.5 * psi2) / denom
    inner = s * (n - s) / n + 0.25 * psi2
    if (inner < 0) inner = 0
    margin = psi * sqrt(inner) / denom
    lcb = center - margin
    if (lcb < 0) lcb = 0
    printf "%.4f\n", lcb
  }'
}
