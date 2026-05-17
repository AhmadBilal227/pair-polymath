# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Pair Polymath is a Claude Code plugin written entirely in **Bash 3.2-portable shell** (no Node, no Python orchestration). Every 5 minutes of an active Claude Code session, `bin/statusline.sh` reads the transcript tail + `git status` + one planner-picked file, fans out **7 parallel LLM analysts** (one per "lens" — UX, Engineering, Security, Perf/FinOps, Product/Biz, Strategic Founder, Cognitive Flow), runs a critique pass, caches surviving observations per-lens, and on the next user prompt the `UserPromptSubmit` hook injects them into Claude's context as a `[BACKGROUND ADVISORY — UNTRUSTED]` block.

The README is the user-facing reference. Architecture details, state-file invariants, and module map live in `docs/architecture.md`.

## Common commands

```bash
bats test/                                  # full test suite
bats test/budget.bats                       # single suite
bats test/cli.bats -f "polymath version"    # single test (bats -f is a substring filter)
shellcheck bin/*.sh lib/*.sh hooks/*.sh     # lint (CI severity: warning)
bash bin/polymath doctor                    # 22 health checks against current install
bash bin/polymath self-test --yes           # one real LLM call, ~$0.0001
bash bin/install.sh --dry-run               # show install plan, mutate nothing
bash bin/install.sh --yes --no-sudo         # headless install (CI / Docker)
```

CI requires green `bats`, `shellcheck`, and `install-test` on every PR (branch protection on `main`). Run them locally before pushing — the loop is faster than waiting on CI.

## Architecture

The cycle: `statusline.sh` (refreshed every 2s by Claude Code) gates on `PP_PARALLEL_INTERVAL_S` (5 min). When the gate opens, `budget.sh` atomically reserves the worst-case 23 calls under a single shared `mkdir`-lock; if that would exceed `PP_MAX_DAILY_CALLS` the cycle is skipped. Then planner picks one file → eligible lenses run in parallel via `bash` subshells → critique pass marks each PASS/DROP/SILENT → drops trigger one retry → 3-cycle drop streaks promote a lens to "deep mode" next cycle. Each surviving observation is written to `$PP_CACHE_DIR/cc-monitor-$SESSION-$LENS.txt` (default `$CLAUDE_DIR/cache/...`; id-keyed, never index-keyed). Current-cycle cache and verdict slots are reset before each run so stale observations do not leak across cycles.

The injection: `hooks/inject-monitor-insight.sh` (UserPromptSubmit) reads those caches (≤30 min old), dedupes by hash + 30 min cooldown, and prints the advisory block on stdout. Claude Code includes that stdout in the next-turn context.

The CLI: `bin/polymath {status,doctor,enable,disable,logs,cost,cache,dismiss,history,oar-label,kpi,retry-router,lens-gates,update,self-test,version}` is the operator surface. `enable`/`disable` toggle `PP_EXTERNAL_LLM` in `$PP_USER_CONFIG` (default `$CLAUDE_DIR/pair-polymath/config/user.env`) with symlink-aware, cross-FS-safe atomic writes.

**Module ownership** (each lib owns one invariant — fix bugs by editing the owner, not the caller):
- `lib/config.sh` — owns canonical `CLAUDE_DIR` / `PP_STATE_DIR` / `PP_CACHE_DIR`, sources `config/default.env` then `$PP_USER_CONFIG`
- `lib/budget.sh` — single source of truth for daily call counter (`mkdir`-lock; `budget_inc` / `budget_reserve` only)
- `lib/grounding.sh` — `pp_contain_path` (realpath prefix match) + secret-file/secret-dir denylist
- `lib/lens-loader.sh` — parses `lenses/*.json`, hard-caps at `PP_LENS_MAX=16`, user `id` overrides built-in
- `lib/prompt-loader.sh` — single-pass `${var}` substitution against the ORIGINAL template (a substituted value containing `${X}` is NEVER re-scanned — secret-leak guard)
- `lib/metrics.sh` — per-cycle USD rollup → `metrics.jsonl`; per-call type stamping
- `lib/doctor.sh` — 22 health checks
- `lib/audit-log.sh` — installer JSONL audit log

**Invariants (don't violate)**:
1. Daily budget is mutated only via `budget_inc` / `budget_reserve` under `${file}.lock`.
2. Cache files are id-keyed (`cc-monitor-$SESSION-$LENS.txt`), never numeric-index-keyed — reordering lenses must not serve stale observations under a wrong identity.
3. All LLM-influenced paths go through `lib/grounding.sh` (`pp_contain_path`, `pp_safe_grep_pattern`).
4. Prompt rendering is single-pass over placeholders found in the original template only.
5. `settings.json` mutations go through `mktemp "${SETTINGS_FILE}.XXXXXX"` (same-FS) + `mv` for atomic-rename-within-filesystem.

## Bash portability rules (from CONTRIBUTING.md)

This codebase targets bash 3.2 (macOS default) and runs on macOS / Ubuntu / Alpine / BusyBox. **Don't introduce**:

- `mapfile` / `readarray` (bash 4+ only) — use `while IFS= read -r`
- `${var,,}` lowercasing (bash 4+) — use `tr '[:upper:]' '[:lower:]'`
- `local -n` nameref (bash 4.3+) — pass via global with `_pp_`-prefix
- `flock` (Linux-only) — use `mkdir`-based atomic locks
- `stat` flag-fallback chains — `stat -f` means different things on GNU vs BSD vs BusyBox. Detect once via probe (`stat -c %Y /dev/null` works on GNU and BusyBox; `stat -f %m /dev/null` works on BSD/macOS) and dispatch on `_PP_STAT_FLAVOR`. See `bin/polymath:29` for the canonical detection.
- `find $missing_path | sort` under `set -eo pipefail` — the SIGPIPE aborts the whole script. Guard with `[ -d "$path" ] &&` or use a temp file.
- Locale-sensitive `awk` `printf "%d"` of floats — non-US locales use `,` as decimal separator. Force `LC_ALL=C` at file top wherever `awk`/`sort`/`grep` parse numerics (see `bin/statusline.sh:12`).
- `local command=...` — shadows the `command` builtin and breaks `command -v jq` later. Use a different variable name.

## Testing conventions

- bats tests use `HOME=$(mktemp -d)` and `CLAUDE_DIR=$HOME/.claude` to stay hermetic — they never touch the developer's real `~/.claude/`.
- Security-relevant fixes need a regression test that fails BEFORE the fix and passes AFTER. Canonical example: `test/prompt-loader.bats` — "substitution values are NOT re-scanned (secret-leak guard)".
- Behavioral changes need at least one bats test. CI is the gate; if `shellcheck` flags warnings, fix them rather than disable.

## Privacy / threat model

What leaves the machine per cycle: last ~5 KB of transcript, `git status` + last 5 commit subjects, first ~3 KB of ONE planner-picked file (containment-checked + secret-denylisted), HN + arXiv RSS titles.

What we actively defend against: recursive `${VAR}` expansion in rendered prompts, files outside cwd, secret-bearing files inside cwd (basename + path-component + cwd-itself denylists in `lib/grounding.sh`), full conversation history.

What we DON'T defend against: secrets the user pasted into the transcript itself.

Every cycle writes a verifiable snapshot to `$PP_CACHE_DIR/last-cycle-payload.json` (default `$CLAUDE_DIR/cache/last-cycle-payload.json`, mode 0600 in 0700 dir) with byte counts + 500-char previews. `polymath status` surfaces its path + age. See `SECURITY.md` and `docs/security.md`.

## Commit / PR style

Lowercase imperative, optional scope: `fix(loader): handle stray } before placeholder`. Body wraps at ~72 chars. `Refs #N` / `Fixes #N`. PRs go through the template at `.github/PULL_REQUEST_TEMPLATE.md`; significant changes get an external `llm -t review-code -m gpt-5` review before merge (documented norm, not a CI gate).

## Useful refs

- `docs/architecture.md` — cycle + sequence diagrams, state-file table, invariants
- `docs/customization.md` — full `PP_*` env reference
- `docs/cost-model.md` — formula behind `polymath cost`
- `docs/troubleshooting.md` — failure modes by doctor check
- `CHANGELOG.md` — every release, with the silent-correctness bugs caught by review listed by PR
