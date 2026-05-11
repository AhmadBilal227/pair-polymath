# Changelog

All notable changes to Pair Polymath are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- M1: Initial repo skeleton extracted from `~/.claude/` (statusline + 2 hooks)
- M2-lean: `config/default.env`, `lib/config.sh`, `lib/budget.sh`, 3 bats suites, shellcheck + bats CI

### Fixed (M2-lean GPT review pass)
- Budget split-lock race: unified `inc` and `reserve` under one shared `${PP_BUDGET_FILE}.lock`
- Cycle gate race: `[ ! -f LOCK ] + touch` → atomic `mkdir LOCK` with stale takeover after 300s
- `session_id` path-injection: strip non-`[a-zA-Z0-9._-]`, cap 64 chars
- `PP_EXTERNAL_LLM=0` now actually skips the cycle (was advertised but unread)
- `PP_ENABLE_ESCALATION=0` now actually disables deep-investigation escalation
- Removed 3 redundant `budget_inc` inside the reserved cycle (double-counted against worst-case-23 reservation)
- Added mixed inc+reserve concurrency test to lock the regression in
