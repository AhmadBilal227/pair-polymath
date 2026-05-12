# Customization

All knobs live in `config/default.env`. To override, copy any line to `~/.claude/pair-polymath/config/user.env` and edit. Variables are sourced default-first, then user-second — so user.env always wins.

## Cap / interval

| Var | Default | Controls |
|---|---|---|
| `PP_MAX_DAILY_CALLS` | `3500` | Hard cap on total LLM calls per UTC day. The cycle gate reserves the worst-case 23 calls atomically; if reserving would push the count over this cap, the cycle is skipped entirely. Raise it if you have a generous OpenAI quota; lower it if you're cost-conscious. |
| `PP_PARALLEL_INTERVAL_S` | `300` | Minimum seconds between full lens cycles. 300 = 5 min. Lower for more frequent observations (costs more); raise for less. |
| `PP_IDLE_THRESHOLD_S` | `1800` | Idle threshold in seconds. If your transcript hasn't changed in this long, the next cycle skips LLM calls entirely (passive mode). Raise if you do long sessions of just thinking; lower for tight-budget sessions. |

## Models

| Var | Default | Controls |
|---|---|---|
| `PP_MODEL` | `gpt-5-mini` | Per-lens analyst model. Cheap + fast is what you want here. |
| `PP_MODEL_DEEP` | `gpt-5.5` | Rotating deep slot + escalation retry. Used for ~1 call per cycle, so the cost impact of upgrading this is bounded. |
| `PP_MODEL_CRITIQUE` | `gpt-5` | Critique pass that PASSes or DROPs each analyst output. Higher reasoning here improves the signal-to-noise ratio significantly. |

## Feature flags

| Var | Default | Controls |
|---|---|---|
| `PP_EXTERNAL_LLM` | `1` | `0` disables all LLM calls (status-only mode). Line 1 still renders; line 2 freezes. `polymath disable` flips this. |
| `PP_ENABLE_ESCALATION` | `1` | `0` disables the deep-investigation escalation pre-pass. Saves ~1-7 calls/cycle when a lens has been dropping ≥3 cycles in a row, at the cost of never escalating. |

## Lens / prompt loader

| Var | Default | Controls |
|---|---|---|
| `PP_LENS_MAX` | `16` | Hard cap on the number of registered lenses. Built-in 7 + your overrides. Lenses beyond the cap are silently dropped (sorted alphabetically by filename). |
| `PP_ROOT` | (auto-detected) | Path to the Pair Polymath checkout. Almost never override — `statusline.sh` resolves this from its own path via `BASH_SOURCE`. Override only when symlinking the script outside the checkout. |

## Containment denylists

Three independent checks reject grounding files even when they live inside cwd: file-basename glob, path-component-is-secret-dir, cwd-itself-is-secret-dir.

| Var | Default | Controls |
|---|---|---|
| `PP_SECRET_FILE_PATTERNS` | (built-in list in `lib/grounding.sh`) | Replaces the basename glob list (escape hatch). Set to `''` to disable file-basename matching entirely. |
| `PP_SECRET_FILE_PATTERNS_EXTRA` | empty | Appended to the built-in basename glob list. Use this if you just want to add patterns (recommended over replacing). |
| `PP_SECRET_DIR_PATTERNS` | (built-in list) | Replaces the directory-name list. Set to `''` to disable. |
| `PP_SECRET_DIR_PATTERNS_EXTRA` | empty | Appended to the built-in dir list. |

Glob patterns are lowercased before matching: `*.PEM` matches `server.pem`.

## Telemetry / prices

These affect ONLY the estimated USD in `polymath cost`. They have NO effect on actual API spend (the price OpenAI charges is what OpenAI charges, regardless of these vars).

| Var | Default | Controls |
|---|---|---|
| `PP_PRICE_GPT_5_MINI_IN_PER_M` | `0.25` | $ per 1M input tokens, gpt-5-mini |
| `PP_PRICE_GPT_5_MINI_OUT_PER_M` | `2.00` | $ per 1M output tokens, gpt-5-mini |
| `PP_PRICE_GPT_5_IN_PER_M` | `1.25` | $ per 1M input tokens, gpt-5 |
| `PP_PRICE_GPT_5_OUT_PER_M` | `10.00` | $ per 1M output tokens, gpt-5 |
| `PP_PRICE_GPT_5_5_IN_PER_M` | `2.50` | $ per 1M input tokens, gpt-5.5 |
| `PP_PRICE_GPT_5_5_OUT_PER_M` | `15.00` | $ per 1M output tokens, gpt-5.5 |

Avg-token vars (used by `polymath cost` when the API didn't report exact token counts):

| Var | Default | Controls |
|---|---|---|
| `PP_AVG_TOK_PLANNER_IN` | `800` | Input tokens per planner call |
| `PP_AVG_TOK_PLANNER_OUT` | `50` | Output tokens per planner call |
| `PP_AVG_TOK_ANALYST_IN` | `2200` | Input tokens per analyst call |
| `PP_AVG_TOK_ANALYST_OUT` | `180` | Output tokens per analyst call |
| `PP_AVG_TOK_CRITIQUE_IN` | `3500` | Input tokens per critique call |
| `PP_AVG_TOK_CRITIQUE_OUT` | `500` | Output tokens per critique call |
| `PP_AVG_TOK_INV_IN` | `1500` | Input tokens per escalation pre-investigation call |
| `PP_AVG_TOK_INV_OUT` | `100` | Output tokens per escalation pre-investigation call |
| `PP_AVG_TOK_RETRY_IN` | `2500` | Input tokens per retry call |
| `PP_AVG_TOK_RETRY_OUT` | `180` | Output tokens per retry call |

Update these if you've measured your actual usage and want sharper estimates.

## Paths (rarely changed)

| Var | Default | Controls |
|---|---|---|
| `PP_CACHE_DIR` | `~/.claude/cache` | Where per-cycle observations, budget tracker, and metrics.jsonl live. |
| `PP_STATE_DIR` | `~/.claude/pair-polymath` | Where user-supplied lenses, prompts, and `user.env` are read from. |

## Memory subsystem (v0.3 Phase 2.3 — off-by-default)

`PP_MEMORY_ENABLE=0` (default) keeps the cycle path byte-identical to `v0.2`. Set to `1` to capture observations to local SQLite, tag them with windowed signals, and inject relevant past observations into future analyst prompts. Full reference: [`docs/memory-architecture.md`](memory-architecture.md).

| Var | Default | Controls |
|---|---|---|
| `PP_MEMORY_ENABLE` | `0` | Master toggle. `1` enables observation capture + injection. |
| `PP_MEMORY_DIR` | `~/.claude/pair-polymath/memory` | Where per-project memory DBs live. |
| `PP_MEMORY_REDACT` | `1` | Apply `pp_memory_redact_body` at store time + inject time. |
| `PP_MEMORY_DECAY_PER_DAY` | `0.5` | Activation decay rate per day since last_seen. |
| `PP_MEMORY_RETRIEVAL_ALPHA` | `0.3` | BM25 weight in hybrid `activation + α × bm25` scoring. |
| `PP_MEMORY_ACTIVATION_K` | `15` | Top-K observations injected per cycle. |
| `PP_MEMORY_INJECT_BODY_CHARS` | `240` | Per-observation body truncation at inject. |
| `PP_MEMORY_PATTERN_INJECT_K` | `5` | Top-N patterns injected per cycle. |
| `PP_MEMORY_MAINTENANCE_EVERY_N` | `12` | Run activation-recompute + eviction + pattern-extraction every Nth cycle. |
| `PP_MEMORY_MAX_BYTES` | `52428800` (50 MB) | DB size budget before eviction fires. |
| `PP_MEMORY_EVICT_BATCH_SIZE` | `100` | Rows evicted per maintenance pass. |
| `PP_MEMORY_PATTERN_BATCH_SIZE` | `200` | Observations sampled per pattern-extraction LLM call. |
| `PP_MEMORY_PATTERNS_MAX` | `1000` | Patterns.jsonl FIFO cap. |
| `PP_MEMORY_LOCK_STALE_S` | `300` | Maintenance-lock stale-takeover threshold (5 min). |
| `PP_MEMORY_LOCK_TIMEOUT_S` | `30` | Max wait for maintenance-lock acquisition. |

Memory observations are local-only. The salted project hash means identical projects on different machines produce different DB paths; the salt does not portably identify a project across machines. See `docs/memory-architecture.md` for the full privacy / threat model.

---

To add a custom lens: drop `~/.claude/pair-polymath/lenses/08-mylens.json` matching the [Lens schema](../README.md#lens-schema). To override the analyst prompt: drop `~/.claude/pair-polymath/prompts/analyst-primary.md` with your text — the loader does `${var}` substitution against the calling scope.
