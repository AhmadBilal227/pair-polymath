# Changelog

All notable changes to Pair Polymath are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [0.1.0-alpha] — 2026-05-11

First tagged release. Private repo only at `github.com/AhmadBilal227/pair-polymath`. Architecture covers lean v1 (M1–M6) plus v0.2 Phase 1 (`polymath doctor`, Docker-Linux installer CI). 66 bats tests across 8 suites.

### Added (Phase 1 of v0.2)
- `polymath doctor` subcommand — 12 strict health checks (bash version, jq, llm, openai key, settings.json validity, statusLine wired, hooks wired, cache writable, budget tracker, lens registry, prompts, statusline smoke) + optional `--network` probe (~$0.0001 to verify live OpenAI reach). Path matching is strict-realpath, not substring.
- `polymath enable` / `polymath disable` subcommands — atomic toggle of `PP_EXTERNAL_LLM` in `user.env` with symlink-aware, cross-filesystem-safe writes and data-loss guards on grep errors.
- `.github/workflows/install-test.yml` — clean Ubuntu installer round-trip CI: removes pre-installed jq, runs installer non-interactively, asserts strict-path matches in `settings.json`, runs `polymath doctor`, runs the bats suite on bash 5, smoke-tests `statusline.sh`, exercises uninstaller.

### Added (Lean v1)
- M1: Initial repo skeleton extracted from `~/.claude/` (statusline + 2 hooks)
- M2-lean: `config/default.env`, `lib/config.sh`, `lib/budget.sh`, 3 bats suites, shellcheck + bats CI
- M3: lens metadata externalized to `lenses/*.json` (7 files), `lib/lens-loader.sh`, `lib/grounding.sh` (containment + grep validators)
  - Eliminates the duplicate-case-statement drift bug between primary and retry analyst paths
  - Eliminates dead `LENS_NAMES` (line 382 stale 5-entry array)
  - User-customizable: drop JSON into `~/.claude/pair-polymath/lenses/` to add/override
- M4: 6 LLM prompts externalized to `prompts/*.md` (planner, analyst-primary, analyst-retry, critique, escalation-investigation, tip-digest), `lib/prompt-loader.sh` with `${var}` substitution
  - User-customizable: drop `.md` into `~/.claude/pair-polymath/prompts/` to override any prompt
  - 6 inline heredoc system prompts → loader calls in `bin/statusline.sh`
- M5-lean: `bin/install.sh`, `bin/uninstall.sh`, `bin/polymath` CLI (`status`, `version`, `help`), `test/cli.bats`
  - Installer auto-detects jq + llm, prompts to install via brew/apt/pip3, prompts for OpenAI key (no-echo), merges `settings.json` with backup
  - Idempotent (re-run safe), preserves third-party hooks, smoke-tests before activating

### Fixed (M5-lean GPT review pass)
- **(HIGH H1)** Installer no longer silently clobbers an existing user `statusLine`: detects conflicts and prompts before replacing (default keep)
- **(HIGH H2)** Uninstaller jq filter now uses `// []` guards: handles `settings.json` where `hooks.UserPromptSubmit` / `PostToolUse` is absent or null
- **(HIGH H3)** Smoke test runs **before** the `settings.json` merge — a broken `statusline.sh` aborts cleanly instead of leaving the user with a broken activated config
- **(MEDIUM M2)** Command strings in `settings.json` now single-quote `$PP_ROOT` paths so installs from a directory with spaces work correctly
- **(MEDIUM M3)** Uninstaller matches by **basename** (e.g. `statusline.sh`, `inject-monitor-insight.sh`): an old install whose checkout was moved/renamed still gets cleaned up
- **(LOW L1)** `polymath status` now honors `$CLAUDE_DIR` consistently with install/uninstall (was hardcoded `$HOME/.claude`)
- **(LOW L2)** `polymath: unknown command` test now asserts on the stderr message, not just exit code
- Post-install PATH check warns if `pip3 --user` placed `llm` outside `$PATH`

### Fixed (M4 GPT review pass)
- **Secret-leak guard (H1)**: substitution is now single-pass over placeholders found in the ORIGINAL template — a critique-LLM-supplied value like `${OPENAI_API_KEY}` can no longer be re-scanned and expanded into the rendered prompt
- LLM calls now guard `[ -n "$_sys" ]` at all 6 sites — a missing/broken prompt no longer silently sends an empty system prompt to the model (also saves budget on no-op calls)
- Replaced `grep | head` placeholder probe with bash regex `[[ =~ ]]` + `BASH_REMATCH` (no pipeline → no `set -e -o pipefail` interaction)
- Fixed infinite-loop bug where a stray `}` before a real placeholder could prevent advancing past the match; now advances by full `${BASH_REMATCH[0]}` length

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
