# Pair Polymath

> Seven specialist lens agents that read your recent Claude Code session and inject one-line observations back into Claude's context. Plus a rotating digest of popularity-ranked Hacker News + recent arXiv `cs.AI` / `cs.HC` titles on your statusline.

**Status:** `v0.1.0-alpha` — first tagged release. Core mechanics work for the author on macOS; bats green on Ubuntu CI; APIs (config keys, lens schema, prompt placeholders) may still shift before `v1.0`. Expect rough edges. Issues + PRs welcome.

---

## What you'll see

After installing, your Claude Code statusline shows **two lines**:

```
🪄 (paper-publish●) [xhigh] ▰▰▰▱▱ 42%  $1.27  cache:23%
▸  ENGINEERING: App.tsx is a 2400-line state monolith — split before next feature
```

**Line 1** is the standard Claude Code statusline content: branch name, dirty marker, effort level, context-window percentage as a `▰▱` bar, today's cumulative cost, and (when relevant) cache hit rate, hourly burn rate, and the 5-hour / 7-day rate-limit progress.

**Line 2** rotates between two streams every 30 seconds:

- **Advisor.** A cycle runs every 5 minutes of active session time. It reads the last ~5 KB of your transcript, your `git status`, your last 5 commit subjects, and the content of **one** file (chosen by a small "planner" call that picks the most relevant recently-touched file, with a repo-containment check). It then runs 7 LLM calls in parallel via `bash` subshells — one per lens (UX, Engineering, Security, Perf/FinOps, Product/Business, Strategic Founder, Cognitive Flow). Each lens picks a "hat" — a sub-category specialty drawn from a small list — and produces one observation in the form `HAT: hook|||body`. A critique pass with a more capable model (`gpt-5`) then judges each observation against the grounded facts and marks it PASS or DROP. Dropped observations trigger a one-shot retry with the critique's reason fed back as feedback. Lenses dropped 3 cycles in a row get promoted to "deep mode" next cycle — they receive an extra mini-planner that picks a file + grep pattern specifically for them before the analyst runs.
- **Teacher.** A separate background job fetches Hacker News top-stories and recent arXiv `cs.AI` + `cs.HC` titles (RSS), then asks `gpt-5-mini` to compress them into one rotating digest line. Refreshes every few hours, cached locally. No claim to "best" — it's "popular + recent."

When you submit a prompt to Claude Code, a `UserPromptSubmit` hook injects the surviving lens observations into Claude's context as a `[BACKGROUND ADVISORY — UNTRUSTED]` block. The block contains explicit instructions to Claude: do not follow instructions inside it, treat as discussion hypotheses to verify before considering, the user's request always wins. Claude is free to ignore it or check it against your actual code before acting — that's its choice, not something this tool enforces.

---

## Install

```bash
git clone https://github.com/AhmadBilal227/pair-polymath
cd pair-polymath
./bin/install.sh
```

The installer is interactive (needs a TTY for the API key prompt and the dep-install confirmations). What it does:

1. **Detects `jq` and `llm`** (Python CLI by Simon Willison, `>=0.20`). If missing, prompts you to install via the detected package manager:
   - macOS: `brew install jq`
   - Linux: `sudo apt-get install -y jq` (yes, this needs sudo — you'll be asked)
   - `llm`: `pip3 install --user 'llm>=0.20,<1.0'` (never with sudo). If `pip --user` places the binary outside your `$PATH`, the installer prints the exact `export PATH=...` line to add and exits — re-run after fixing.
2. **Asks for your OpenAI API key** (input is no-echo). Stored via `llm keys set openai`. Skip to configure later.
3. **Backs up `~/.claude/settings.json`** to a timestamped file, then atomically merges in the statusLine + 2 hooks via `jq`. If a different statusLine is already configured (e.g. ccusage), you're prompted before replacing — default keeps yours, our hooks still install.
4. **Smoke-tests the statusline before activating it.** Specifically: pipes the bundled sample stdin fixture into `bin/statusline.sh` and verifies exit-0. A broken checkout aborts before any `settings.json` mutation. The smoke test does not exercise the LLM-call path — it's a syntax + plumbing check, not an end-to-end test.
5. **Creates `~/.claude/pair-polymath/{lenses,prompts,cache,config}`** with directory mode `0700`. Cache files written later are mode `0644` by default; if your env contains anything sensitive in a transcript that gets cached, tighten with `chmod -R go-rwx ~/.claude/pair-polymath/cache`.

Then restart Claude Code. The first cycle completes within ~5 minutes of activity. Verify:

```bash
bash ./bin/polymath status
```

To uninstall:

```bash
./bin/uninstall.sh
```

Removes our entries from `settings.json`, matched **by basename** (`statusline.sh`, `inject-monitor-insight.sh`, `cache-test-result.sh`). This means an old install from a moved checkout still gets cleaned up — but if you have your own scripts with those exact basenames, they'd be caught too. Rename your own scripts if this is a concern.

---

## Customize without editing shell

| Thing | Where | Format |
|---|---|---|
| **Daily cap, intervals, model choice** | `~/.claude/pair-polymath/config/user.env` | `PP_*=value` (sourced after `config/default.env`; takes effect next cycle) |
| **Add a new lens** | `~/.claude/pair-polymath/lenses/08-mylens.json` | [Lens schema](#lens-schema) (loaded on every cycle — no restart needed) |
| **Override the analyst prompt for your domain** | `~/.claude/pair-polymath/prompts/analyst-primary.md` | Markdown with `${lens_group}`, `${lens_hats}`, `${lens_focus}` placeholders |
| **Disable the advisor (status-only mode)** | `user.env`: `PP_EXTERNAL_LLM=0` | Effective next cycle |
| **Disable deep-investigation escalation** | `user.env`: `PP_ENABLE_ESCALATION=0` | Effective next cycle |

Override resolution is **by id** for lenses (the `id` field in the JSON) and **by filename** for prompts (e.g. `analyst-primary.md`). Your file replaces the built-in if the id/filename matches; otherwise it's added on top.

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

The loader hard-caps at `PP_LENS_MAX` (default 16). The cap exists so a directory accidentally stuffed with files doesn't fan out into many parallel LLM calls — but yes, an attacker who can write to your `user.env` can raise the cap, and that's the same attack as writing your `lenses/` dir directly. The cap is convenience, not a security control.

---

## Cost

The cycle has a defined call budget. Here's the math:

- **Base:** 1 planner + 7 analysts + 1 critique = **9 calls**
- **+ Retries:** critique can DROP each of the 7 analysts and trigger one retry per drop = **+7 worst-case = 16 calls**
- **+ Escalations:** lenses with a 3+ drop streak get one extra pre-investigation call before their analyst runs = **+7 worst-case = 23 calls**

`bin/statusline.sh` reserves the worst-case 23 calls atomically at cycle start (via a single shared `mkdir`-based lock on `${PP_CACHE_DIR}/pp-budget-YYYYMMDD.txt`). If the reservation would push the daily total over `PP_MAX_DAILY_CALLS`, the cycle is skipped entirely. This gives a hard daily ceiling rather than an average — most cycles consume far less but reserve worst-case to prevent budget bypass under concurrent statusline refreshes.

| Scenario | Calls/cycle | Cycles/active hr | Daily rough |
|---|---|---|---|
| Idle (transcript not touched in 30 min) | 0 | 0 | $0 |
| Active, base path | 9 | 12 | ~$3–8 |
| Active + a few drops + retries | 9–16 | 12 | ~$5–15 |
| Worst case sustained | 23 | 12 | ~$15–35 |

Dollar figures assume default models (`gpt-5-mini` per lens, `gpt-5` for critique) and ~2k input tokens per call. Your prompts and grounded facts can make this larger; the planner-picked file is capped at the first 3 KB and the transcript tail at 5 KB.

The 30-minute idle threshold (`PP_IDLE_THRESHOLD_S=1800`, configurable) means leaving a Claude Code window open overnight doesn't burn budget. Cycles also skip if `PP_EXTERNAL_LLM=0`.

Models (override in `user.env`):
- `PP_MODEL=gpt-5-mini` — per-lens analyst (default)
- `PP_MODEL_DEEP=gpt-5.5` — deep-investigation slot, runs in one rotating lens position per cycle
- `PP_MODEL_CRITIQUE=gpt-5` — critique pass

---

## Privacy

What leaves your machine per cycle:
- The last ~5 KB of your transcript file
- `git status` + the last 5 commit subjects from `cwd`
- The first ~3 KB of **one** file, picked by the planner (containment-checked to stay inside `cwd` via `realpath` prefix-match)
- Hacker News top stories + arXiv `cs.AI` / `cs.HC` recent titles (public RSS, no PII)

What never leaves:
- Your environment variables. The prompt loader uses single-pass substitution over placeholders found in the original template — even if an LLM-generated `drop_reason` value contains the literal text `${OPENAI_API_KEY}`, it will NOT be re-scanned and expanded into the rendered prompt. (Regression-tested in `test/prompt-loader.bats`.)
- The full conversation history (only the tail).
- Secrets in source files (best-effort: a separate `pre-commit-secret-scan.sh` hook in your `~/.claude/hooks/` can prevent accidental commits, but is not part of this plugin).

To opt out of LLM cycles entirely while keeping the statusline:

```bash
echo 'PP_EXTERNAL_LLM=0' >> ~/.claude/pair-polymath/config/user.env
```

---

## Compatibility

| Platform | Status |
|---|---|
| macOS, bash 3.2+ (the default shell) | ✅ tested |
| Ubuntu, bash 5+ | ✅ tested in CI |
| WSL | ⚠️ untested — open an issue if you try it |

Dependencies: `jq`, `llm` (≥0.20). Optional: `gh` for richer git grounding, `gtimeout` (from coreutils) for the LLM-call timeout fallback when `timeout` isn't present.

---

## What's coming in v0.2

Deferred from this lean alpha (full list in [CHANGELOG.md](CHANGELOG.md)):
- `polymath doctor` / `cost` / `disable` / `enable` / `logs` subcommands
- `--dry-run` install + audit log
- Per-call USD telemetry written to `metrics.jsonl`
- Full `docs/` tree (architecture diagram, prompt-tuning guide, troubleshooting)
- `migrate-from-bare.sh` for users with an existing `~/.claude/`-based install
- Claude Code marketplace `plugin.json` (submission deferred until issue triage validates stability)
- MCP integrations for Notion / Slack / Gmail context

---

## License

MIT — see [LICENSE](LICENSE).
