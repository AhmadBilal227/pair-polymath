# Changelog

All notable changes to Pair Polymath are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [0.2.0] — 2026-05-12

Second release. Ships the trust-building feature set: USD cost transparency, verifiable privacy log, headless installer, end-to-end self-test, and a documentation tree. **247 bats tests across 11 suites.** Required CI green on every PR under β branch protection (PRs only, status checks required, linear history).

### Added — Cost transparency (P3.1 + P3.2)
- **`metrics.jsonl`** — USD telemetry rolled up per cycle. Stamps per-call type (`analyst-primary`, `analyst-retry`, `critique`, `escalation`, `tip-digest`, `planner`) with model + token counts + computed USD via a versioned per-model price table.
- **`polymath cost`** — last-7-day spend table with `--since`, `--by-lens`, `--json` flags. 4-decimal USD precision so sub-cent sessions stay visible. `LC_ALL=C` wrapper around `awk` so non-US locales produce parseable rows.
- **`metrics-warnings.log`** — unknown-model billing surfaced (was silently $0 before).

### Added — Privacy + verifiability (P3.3)
- **`last-cycle-payload.json`** — single overwriting JSON at `$PP_CACHE_DIR/last-cycle-payload.json` showing what the most recent cycle would have sent to OpenAI: lens count, both models, planner-picked file, byte counts (UTF-8-accurate via `wc -c`), and 500-char previews of transcript + grounded facts. Mode 0600 in a 0700 dir.
- **`polymath status` surfaces the path + age** when the file exists so users can verify the README "what leaves your machine" claim with their own eyes.

### Added — Installer hardening (P2.3)
- **`install.sh --dry-run / --yes / --no-sudo / --non-interactive`** flags. Headless install in CI / Docker is now real; `install-test.yml` drops the stdin-piped answers trick.
- **Audit log** at `$CLAUDE_DIR/pair-polymath/install.log` — JSONL of every action with exit code + truncated stderr. Fallback path is jq-free for ultra-early install steps.
- **Bare-install detection** — counter at `cache/migration-requests.txt` tracks users with an existing pre-plugin `~/.claude/` setup.

### Added — End-to-end LLM probe (P4 self-test)
- **`polymath self-test`** — single real call (~$0.0001 on `gpt-5-mini`) against a fixed sentinel. Verifies key + network + run_llm wrapper + budget integration + response parseability in one shot. Sentinel mismatch exits non-zero (no false-pass).

### Added — Subcommands (P2.1 + P2.2 + P2.4)
- **`polymath enable` / `polymath disable`** — atomic toggle of `PP_EXTERNAL_LLM` with symlink-aware, cross-FS-safe writes and data-loss guards.
- **`polymath logs`** — tail recent lens observations with `-n`, `--lens`, `--follow`.
- **`polymath update`** — pull latest + re-run installer with `--yes`, `--dry-run`.

### Added — Documentation tree (P4 docs)
- `docs/architecture.md` — cycle + sequence diagrams, module map, state-file invariants
- `docs/customization.md` — full `PP_*` env reference
- `docs/cost-model.md` — formula behind `polymath cost`
- `docs/troubleshooting.md` — common failure modes by doctor check
- `docs/security.md` — operational companion to SECURITY.md
- `docs/demo-recipe.md` — asciinema recording procedure

### Fixed — Silent-correctness bugs caught by triple-review Ralph loop
The PR review process (code-reviewer agent + debugger agent + GPT-5.5 `llm -t review-code`) found these across 8 PRs:
- **Locale-sensitive `awk` decimals** → `de_DE.UTF-8` users produced unparseable metrics rows (PR #10).
- **`jq add` key-collision** masquerading as numeric sum → `polymath cost --by-lens` undercounted multi-session totals (PR #10).
- **Unknown model billed as $0** → non-default providers (`claude-*`, local, `gpt-4o`) got dangerously low estimates without warning (PR #10).
- **Signal-trap continuation** → `INT`/`TERM` could let cycles run after lock release (PR #10 R3).
- **Concurrent `metrics.jsonl` append corruption** → parallel cycles could interleave writes (PR #10 R3).
- **`bash` builtin shadowing** (`local command=...` breaking `command -v jq`) → silent install failure on Ubuntu bash 5 strict mode, undetected on macOS bash 3.2 (PR #13).
- **`find $missing_path | sort` aborts under `-eo pipefail`** before installer code runs → install-dry-run CI swallowed all diagnostics (PR #15).
- **`mktemp` cross-FS atomicity** → tmp on a different FS than target could fail mv on `/var/tmp → /tmp` boundaries (PR #13).
- **Privacy log world-readable** → default umask 022 made transcript previews readable by anyone on the box (PR #17 R2).
- **Privacy log fixed `${out}.tmp` race** → concurrent statusline cycles could write to the same tmp (PR #17 R2).
- **Multibyte byte counts** → `${#var}` is char-count under UTF-8, undercounted non-ASCII transcripts (PR #17 R2).
- **Self-test sentinel mismatch silently exited 0** → advertised verification was a false-pass (PR #16 R2).
- **Self-test `budget_inc` before LLM rc check** → failed calls corrupted the daily counter (PR #16 R2).

### Infra
- Sprint A: branch protection enabled (`bats`, `shellcheck`, `install-clean-ubuntu` required), `CONTRIBUTING.md` / `SECURITY.md` / `CODE_OF_CONDUCT.md` added.
- Sprint B: README polished with badges, use cases, real observation samples, comparison table, FAQ.
- `install-test.yml` clean-Ubuntu round-trip + dry-run job.

### Known follow-ups (deferred to v0.3)
- Issue #11: `NO_COLOR` / `--no-color` support across all printers (A11Y).
- Issue #12: per-model price config externalized so users can ship their own price table.

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
