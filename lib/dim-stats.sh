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
