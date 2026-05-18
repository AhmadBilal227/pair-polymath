#!/usr/bin/env bash
# v0.5.5 brand — subagent statusline hook.
#
# Claude Code passes ALL visible subagent rows as a single JSON object on
# stdin (per https://code.claude.com/docs/build-with-claude/statusline#subagent-status-lines).
# We emit one JSON line per row we want to override, in the form:
#   {"id": "<task id>", "content": "<row body>"}
#
# Polymath-spawned subagents (the lens fan-out + critique + retries) are
# identified by name pattern. Other subagents are passed through (no row
# override) — the user's own work isn't branded.
#
# Voice: monochrome ⚛ (per ui-designer review — 7 simultaneous lens-
# colored rows would strobe). The brand mark says "this row came from
# polymath." Lens identity lives in the existing name/description.

set -u
umask 077

# Lazy-source brand helpers. Skip silently if unavailable — the hook
# degrades to "no row overrides," same as if the hook were absent.
PP_ROOT="${PP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$PP_ROOT/lib/brand.sh" 2>/dev/null || exit 0
type pp_brand_sigil_plain >/dev/null 2>&1 || exit 0

# Read the full subagent JSON envelope from stdin.
input=$(cat 2>/dev/null || echo '{}')

# Without jq we can't safely parse the JSON. Bail; Claude Code falls
# back to default rendering.
command -v jq >/dev/null 2>&1 || exit 0

# Polymath-spawned subagents: name matches the analyst / critique /
# retry / planner patterns we use in bin/statusline.sh. Conservative
# matching — only patterns we KNOW we own get branded. Anything else
# passes through (no override line emitted).
_pp_sigil="$(pp_brand_sigil_plain)"
# Row body shape: ⚛ + original name + (optional) lens hint from description.
# Token count omitted — Claude Code default already shows it; we only
# override the leading identity, not the metrics.
printf '%s' "$input" | jq -rc --arg sigil "$_pp_sigil" '
  .tasks // [] | .[] |
  select(
    (.name // "" | test("^(analyst|critique|planner|retry|inv)"; "i"))
    or (.name // "" | test("polymath"; "i"))
    or (.description // "" | test("polymath"; "i"))
  ) |
  { id: .id, content: ($sigil + " " + (.name // "polymath") + " · " + (.description // "lens")) }
' 2>/dev/null || true

exit 0
