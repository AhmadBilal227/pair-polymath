# Pair Polymath

> Seven specialist lens agents that shadow your Claude Code session and quietly curate the field's best learning signals. Advisor + teacher in one statusline.

**Status:** `v0.1.0-pre` (alpha). Architecture is stable; the public release tag (`v0.1.0-alpha`) lands once the author has dogfooded it for a week without surprises.

---

## What you'll see

After installing, your Claude Code statusline shows **two lines** instead of one:

```
🪄 (paper-publish●) [xhigh] ▰▰▰▱▱ 42%  $1.27  cache:23%
▸  ENGINEERING: App.tsx is a 2400-line state monolith — split before next feature
```

Line 1 is the standard status (branch, dirty marker, effort, context-window bar, today's cost, cache hit, rate-limit headroom).

Line 2 rotates between two streams:

- **Advisor:** observations from one of 7 lens agents that watched your last 5 minutes of work — a cycle reads your transcript tail, picks a file you touched, and runs 7 parallel LLM analyses (UX, Engineering, Security, Perf/FinOps, Product/Business, Strategic Founder, Cognitive Flow). Each picks a "hat" and produces one concrete `HAT: hook|||body` observation. A separate critique pass with a more capable model drops weak/redundant/hallucinated ones, and a streak counter promotes drowned-out lenses to deeper investigation next cycle.
- **Teacher:** rotating digests of the day's best signals from Hacker News + arXiv `cs.AI` / `cs.HC` — concise enough to absorb while you wait for a build.

When you submit a new prompt to Claude Code, a `UserPromptSubmit` hook injects the recent surviving observations into Claude's context as a `[BACKGROUND ADVISORY — UNTRUSTED]` block, so Claude can verify them against your code before acting. The block is loud about untrustedness; Claude treats it as discussion fuel, not commands.

---

## Install

```bash
git clone https://github.com/<user>/pair-polymath
cd pair-polymath
./bin/install.sh
```

The installer:
1. Detects `jq` and `llm` (Python CLI). Prompts to install via `brew` / `apt-get` / `pip3 --user` if missing — never installs with sudo automatically.
2. Asks for your OpenAI API key (no-echo input) and stores it via `llm keys set openai`. Skip the prompt to configure later.
3. Backs up `~/.claude/settings.json`, then atomically merges in the statusLine + 2 hooks. If you already have a statusLine configured (e.g. ccusage), it prompts before replacing — defaults to keeping yours.
4. Smoke-tests the statusline before activating it. A broken checkout aborts cleanly with `settings.json` untouched.
5. Creates `~/.claude/pair-polymath/{lenses,prompts,cache,config}` (0700, owner-only) for your overrides.

Then start (or restart) a Claude Code session. The first lens cycle completes within ~5 minutes of activity. Verify:

```bash
bash ./bin/polymath status
```

To uninstall:

```bash
./bin/uninstall.sh
```

Removes our `settings.json` entries (matched by basename, so even old installs from moved checkouts are cleaned up). Preserves third-party hooks. Prompts before deleting your override dir.

---

## Customize without editing shell

| Thing | Where | Format |
|---|---|---|
| **Daily cap, intervals, model choice** | `~/.claude/pair-polymath/config/user.env` | `PP_*=value` |
| **Add a new lens** | `~/.claude/pair-polymath/lenses/08-mylens.json` | [Lens JSON schema](#lens-schema) |
| **Override the analyst prompt for your domain** | `~/.claude/pair-polymath/prompts/analyst-primary.md` | Markdown with `${lens_group}`, `${lens_hats}`, `${lens_focus}` placeholders |
| **Disable the advisor (status-only mode)** | `user.env`: `PP_EXTERNAL_LLM=0` | — |
| **Disable deep-investigation escalation** | `user.env`: `PP_ENABLE_ESCALATION=0` | — |

Built-in lenses, prompts, and defaults always serve as fallbacks; your overrides shadow them by name. Drop a JSON or `.md` file in place and restart your session — no reinstall.

### Lens schema

```json
{
  "version": 1,
  "id": "MY_LENS",
  "display_order": 8,
  "hats": ["HAT_A", "HAT_B"],
  "focus": "what this lens looks for — short paragraph",
  "color_hex": "#06b6d4",
  "enabled": true,
  "extras": {}
}
```

The loader hard-caps at 16 lenses (`PP_LENS_MAX` override) so a stuffed directory can't turn a refresh into a parallel-LLM cost bomb.

---

## Cost

| Scenario | Calls per cycle | Cycles per active hour | Daily cost (rough) |
|---|---|---|---|
| Idle (no transcript activity in 30 min) | 0 | 0 | $0 |
| Active session, base path | 9 | 12 | ~$3–8 |
| Active + critique drops + retries | up to 16 | 12 | ~$5–15 |
| Worst case (all retries + all 7 escalations fire) | 23 | 12 | ~$15–35 |

A worst-case 23 calls is **reserved atomically** at cycle start, so `PP_MAX_DAILY_CALLS` (default 3500) cannot be exceeded even under drop-storm conditions. The reservation also means the daily cap is a hard ceiling, not an average — most cycles consume far less but reserve worst-case to prevent budget bypass under concurrent statusline refreshes.

Cycles skip entirely if your transcript hasn't been modified in `PP_IDLE_THRESHOLD_S` seconds (default 1800 = 30 min), so leaving a Claude Code window open doesn't burn budget overnight.

Models (override in `user.env`):
- `PP_MODEL=gpt-5-mini` — per-lens analyst (default)
- `PP_MODEL_DEEP=gpt-5.5` — deep-investigation slot when a lens has a 3+ drop streak
- `PP_MODEL_CRITIQUE=gpt-5` — the critique pass that drops weak observations

---

## Privacy

What leaves your machine:
- The last ~5 KB of your transcript file
- `git status` + the last 5 commit subjects of the cwd
- The content of **one** file each cycle, picked by a planner (containment-checked to stay inside `cwd`)
- Hacker News top stories + arXiv `cs.AI` / `cs.HC` recent titles (public RSS, no PII)

What never leaves:
- Your environment variables (the prompt loader uses single-pass substitution so an LLM cannot exfiltrate `${OPENAI_API_KEY}`-style values into rendered prompts)
- Secrets in source files (best-effort: see the pre-commit secret-scan hook example)
- Full conversation history (only the tail)

To opt out of LLM cycles entirely while keeping the statusline:

```bash
echo 'PP_EXTERNAL_LLM=0' >> ~/.claude/pair-polymath/config/user.env
```

---

## Compatibility

| Platform | Status |
|---|---|
| macOS, bash 3.2+ (default shell) | ✅ tested |
| Ubuntu, bash 5+ | ✅ tested (CI) |
| WSL | ⚠️ untested — open an issue if you try it |

Dependencies: `jq`, `llm` (Python CLI by Simon Willison, ≥0.20). Optional: `gh` for richer git grounding, `gtimeout` (from coreutils) for the LLM call timeout.

---

## What's coming in v0.2

Deferred from this lean alpha:
- `polymath doctor` / `cost` / `disable` / `enable` / `logs` subcommands
- `--dry-run` install + audit log
- Per-call USD telemetry exported to `metrics.jsonl`
- Full `docs/` tree (architecture diagram, prompt-tuning guide, troubleshooting)
- `migrate-from-bare.sh` for users with an existing `~/.claude/`-based install
- Claude Code marketplace `plugin.json` (submission deferred until a few weeks of issue triage validates stability)
- MCP integrations for Notion / Slack / Gmail context (the "knows your contacts" angle)

---

## License

MIT — see [LICENSE](LICENSE).

`v0.1.0-pre` is alpha. Issues and PRs welcome. The author dogfoods this; expect rapid iteration.
