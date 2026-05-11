# Changelog

All notable changes to Pair Polymath are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- M1: Initial repo skeleton extracted from `~/.claude/` (statusline + 2 hooks)
- M2-lean: `config/default.env`, `lib/config.sh`, `lib/budget.sh`, 3 bats suites, shellcheck + bats CI
- M3: lens metadata externalized to `lenses/*.json` (7 files), `lib/lens-loader.sh`, `lib/grounding.sh` (containment + grep validators)
  - Eliminates the duplicate-case-statement drift bug between primary and retry analyst paths
  - Eliminates dead `LENS_NAMES` (line 382 stale 5-entry array)
  - User-customizable: drop JSON into `~/.claude/pair-polymath/lenses/` to add/override

### Fixed (M3 GPT review pass)
- Lens count cap (`PP_LENS_MAX`, default 16): stuffed user dir can no longer turn a refresh into a parallel-LLM cost bomb
- `pp_safe_grep_pattern`: reject leading `-` (option injection guard), require ≥3 alnum chars (dwarfed-by-metachars guard)
- Cache filenames id-keyed (`cc-monitor-${session_id}-${lens_id}.txt`) instead of index-keyed: surviving lens reorder/disable without stale-data bugs
- `pp_load_lenses` now returns 1 + stderr warning on zero lenses loaded (was silent)
- Stable tiebreak by id when `display_order` ties (deterministic ordering)
- Test hermeticity: `lens-loader.bats` uses `HOME=$(mktemp -d)` so developer's real user-override dir doesn't pollute tests

### Fixed (M2-lean GPT review pass)
- Budget split-lock race: unified `inc` and `reserve` under one shared `${PP_BUDGET_FILE}.lock`
- Cycle gate race: `[ ! -f LOCK ] + touch` → atomic `mkdir LOCK` with stale takeover after 300s
- `session_id` path-injection: strip non-`[a-zA-Z0-9._-]`, cap 64 chars
- `PP_EXTERNAL_LLM=0` now actually skips the cycle (was advertised but unread)
- `PP_ENABLE_ESCALATION=0` now actually disables deep-investigation escalation
- Removed 3 redundant `budget_inc` inside the reserved cycle (double-counted against worst-case-23 reservation)
- Added mixed inc+reserve concurrency test to lock the regression in
