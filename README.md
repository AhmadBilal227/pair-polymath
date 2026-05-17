# Pair Polymath

**Seven specialist AI lenses watch your Claude Code session and whisper one-line concerns back to Claude before your next prompt.**

UX. Engineering. Security. Perf/FinOps. Product/Biz. Strategic Founder. Cognitive Flow. Each one reads the transcript tail + git status + one file (its own pick), produces one observation, gets critique-judged, and the survivors land in Claude's context as a `[BACKGROUND ADVISORY — UNTRUSTED]` block. Claude can verify, ignore, or push back. You stay in control.

[![bats](https://github.com/AhmadBilal227/pair-polymath/actions/workflows/bats.yml/badge.svg)](https://github.com/AhmadBilal227/pair-polymath/actions/workflows/bats.yml) [![shellcheck](https://github.com/AhmadBilal227/pair-polymath/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/AhmadBilal227/pair-polymath/actions/workflows/shellcheck.yml) [![install-test](https://github.com/AhmadBilal227/pair-polymath/actions/workflows/install-test.yml/badge.svg)](https://github.com/AhmadBilal227/pair-polymath/actions/workflows/install-test.yml) ![macOS](https://img.shields.io/badge/macOS-tested-success) ![Ubuntu](https://img.shields.io/badge/Ubuntu-CI%20verified-success) ![bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-orange) ![v0.5.2.1](https://img.shields.io/badge/version-0.5.2.1-blue) ![tests](https://img.shields.io/badge/bats-862%20green-success) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## What you see

```
🪄 (paper-publish●) [xhigh] ▰▰▰▱▱ 42%  $1.27  cache:23%
▸  ENGINEERING: App.tsx is a 2400-line state monolith — split before next feature
```

**Line 1** — standard Claude Code statusline (branch, context%, today's spend).
**Line 2** — rotates every 30s between **advisor** (one of 7 lens observations) and **teacher** (a rotating digest of popularity-ranked HN + recent arXiv `cs.AI` / `cs.HC` titles, compressed by `gpt-5-mini`).

## Real example: caught a bug in its own installer

> The ENGINEERING lens flagged `mktemp in install/uninstall can create tmp on other FS`. Investigation confirmed: `bin/install.sh` used bare `mktemp` (defaults to `/tmp`), then `mv "$tmp" "$SETTINGS_FILE"`. On Linux with `/tmp` as tmpfs, that `mv` crosses filesystems — copy+delete, not atomic. A partial read by Claude Code is a real race. Fix shipped in [PR #3](https://github.com/AhmadBilal227/pair-polymath/pull/3). The proposition: hypotheses surfaced earlier, not a guarantee.

## Install

```bash
git clone https://github.com/AhmadBilal227/pair-polymath
cd pair-polymath
./bin/install.sh
```

Needs a TTY (API key prompt). Detects `jq` + `llm` (≥0.20) and walks you through installing what's missing. Backs up `~/.claude/settings.json` before merging in our statusLine + 2 hooks atomically. Restart Claude Code; first cycle runs within ~5 minutes of activity.

Verify: `bash ./bin/polymath doctor` (22 health checks). Uninstall: `./bin/uninstall.sh`.

## Cost

| Scenario | Calls / cycle | ~Daily ($) |
|---|---:|---:|
| Idle (30 min no transcript change) | 0 | 0 |
| Active, base path | 9 | 3–8 |
| Active + drops + retries | 9–16 | 5–15 |
| Worst case sustained | 23 | 15–35 |

Hard cap on **call count** via `PP_MAX_DAILY_CALLS=3500` (atomic `mkdir`-locked reservation per cycle). See actual spend: `polymath cost --since 30d`. Disable for sensitive sessions: `polymath disable`.

## Privacy in one paragraph

What leaves per cycle: ~5 KB transcript tail, `git status` + last 5 commit subjects, ~3 KB of ONE planner-picked file (containment-checked, 30+ secret-bearing basename + path-component denylists in [`lib/grounding.sh`](lib/grounding.sh)), public HN + arXiv RSS titles. NEVER: full conversation history, files outside cwd, recursively-expanded `${VAR}` values in prompts. **At risk:** secrets you pasted INTO your transcript. Every cycle writes a verifiable snapshot to `~/.claude/cache/last-cycle-payload.json`. Full threat model: [SECURITY.md](SECURITY.md) + [docs/security.md](docs/security.md).

## Customize without editing shell

| Thing | Where |
|---|---|
| Daily cap / intervals / model choice | `~/.claude/pair-polymath/config/user.env` (`PP_*=value`) |
| Add a new lens | `~/.claude/pair-polymath/lenses/08-mylens.json` ([schema](docs/customization.md)) |
| Override the analyst prompt | `~/.claude/pair-polymath/prompts/analyst-primary.md` |
| Disable advisor (status-only) | `polymath disable` |
| Inspect lens-gates kill-switches | `polymath lens-gates status` |

## How it's different

| Tool | What it does | Pair Polymath adds |
|---|---|---|
| [ccusage](https://github.com/ryoppippi/ccusage) | Token spend in statusline | Cost + **7 advisor observations injected into Claude's context** + learning digests |
| [ccstatusline](https://github.com/sirmalloc/ccstatusline) | Configurable statusline | Status + **per-cycle parallel-LLM advisory team** with critique gate |
| [aider](https://aider.chat/) | Writes code | Different category — Pair Polymath does NOT write code; it **whispers** to Claude, who decides |
| LSP servers | Syntactic/type warnings | One level up — **multi-disciplinary cross-cutting concerns** no LSP surfaces |

## Status

**Latest:** [`v0.5.2.1`](https://github.com/AhmadBilal227/pair-polymath/releases/tag/v0.5.2.1) — planner / grounding fix. Three changes (SILENT first-class, FILE-READ-derived symbol inventory unified between lens prompts and validator, planner eligibility gates per lens). All shadow-by-default behind 4 kill-switches; STDOUT byte-identical to v0.5.2.0 until you opt in. 862/862 bats green; dual-write schema migration preserves v0.5.2.0 reader compatibility.

**Recent:** [`v0.5.2.0`](https://github.com/AhmadBilal227/pair-polymath/releases/tag/v0.5.2.0) — OAR (Observation→Action Rate) measurement plumbing + shadow-by-default hallucination verifier.

Both releases ran through 3 rounds of GPT-5 coworker spec review + multi-reviewer-per-task implementation, which caught 17+ silent-correctness bugs pre-merge. See [CHANGELOG.md](CHANGELOG.md) for the bug-catch log.

APIs (config keys, lens schema, prompt placeholders, OAR schema) may still shift before `v1.0`. Issues + PRs welcome.

## Compatibility

macOS bash 3.2+ ✅ · Ubuntu bash 5+ ✅ (CI verified) · WSL ⚠ untested (open an issue if you try). Deps: `jq`, `llm` (≥0.20). Optional: `gh`, `gtimeout`.

## Docs

- [`docs/architecture.md`](docs/architecture.md) — cycle + sequence diagrams, state-file invariants, module map
- [`docs/customization.md`](docs/customization.md) — full `PP_*` env reference + lens schema
- [`docs/cost-model.md`](docs/cost-model.md) — the formula behind `polymath cost`
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — failure modes by doctor check
- [SECURITY.md](SECURITY.md) — threat model
- [CHANGELOG.md](CHANGELOG.md) — every release, with the silent-correctness bugs caught by review

## License

MIT — see [LICENSE](LICENSE).
