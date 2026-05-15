# Customization

All knobs live in `config/default.env`. To override, copy any line to `~/.claude/pair-polymath/config/user.env` and edit. Variables are sourced default-first, then user-second — so user.env always wins.

## Cap / interval

| Var | Default | Controls |
|---|---|---|
| `PP_MAX_DAILY_CALLS` | `10000` | Hard cap on total LLM calls per local-day budget file. The cycle gate reserves the worst-case 23 calls atomically; if reserving would push the count over this cap, the cycle is skipped entirely. Was 3500 in v0.2; bumped to 10000 in v0.4 because multi-session users were silently exhausting it mid-day. Raise it if you have a generous OpenAI quota; lower it if you're cost-conscious. |
| `PP_PARALLEL_INTERVAL_S` | `300` | Minimum seconds between full lens cycles. 300 = 5 min. Lower for more frequent observations (costs more); raise for less. |
| `PP_IDLE_THRESHOLD_S` | `1800` | Idle threshold in seconds. If your transcript hasn't changed in this long, the next cycle skips LLM calls entirely (passive mode). Raise if you do long sessions of just thinking; lower for tight-budget sessions. |
| `PP_BUDGET_WARN_PCT` | `80` | % USED at which the line-1 statusline starts showing an amber pip (`⚡N%` remaining) and `polymath doctor` flips yellow for the "budget pressure" check. Set lower (e.g. `60`) to be warned earlier. Must be `< PP_BUDGET_RED_PCT`; inversions reset to defaults with a yellow doctor diagnostic. |
| `PP_BUDGET_RED_PCT` | `95` | % USED at which line-1 turns the pip red (`⚠N%`), the line-2 idle fallback says "paused — daily budget near cap; resets at local midnight", and `polymath doctor` flips red with a remediation hint. |
| `PP_DISPLAY_STALE_S` | `max(900, 3*PP_PARALLEL_INTERVAL_S)` | Maximum age in seconds before a cached lens observation is considered stale and skipped during rotation (line 2 falls through to the global tip or idle message). Default scales with the cycle interval so a delayed cycle doesn't stampede all lens caches into "stale" at once. The default is computed at runtime — override only if you want to pin a fixed window. |
| `PP_DISMISS_AUTO_THRESHOLD` | `10` | When the same observation hash appears in `cc-monitor-injected-hash-*` files across this many sessions within `PP_DISMISS_AUTO_WINDOW_DAYS`, `pp_dismiss_auto_suppress` automatically adds a 7-day TTL rule. Excluded if you ran `polymath dismiss ack <hash-prefix>` first. Lower for more aggressive auto-suppress; higher for fewer false-positives. |
| `PP_DISMISS_AUTO_WINDOW_DAYS` | `30` | Window for the auto-suppress counter (uses file mtime via `find -mtime`). Counts only hash-files modified within this many days. |
| `PP_DISMISS_TTL_EXTEND_DAYS` | `3` | Each match of an auto-suppress rule's hash extends the rule's `ttl_days` by this many days, up to `PP_DISMISS_TTL_CAP_DAYS`. |
| `PP_DISMISS_TTL_CAP_DAYS` | `30` | Hard cap on auto-suppress TTL extension. At cap, the rule promotes to `source=auto_suppress_persisted` (permanent until `polymath dismiss disable <id>`). |
| `PP_DISMISS_RENDERED_MAX_BYTES` | `2048` | Byte cap on the `${project_constraints}` block injected into analyst LLM system prompts. Truncates at last full bullet — never mid-bullet. |
| `PP_RETRY_ROUTER_ENABLE` | `0` | Master gate for cost-aware retry router. `0`=v0.5.0 behavior unchanged; `1`=route retries by confidence (premium model only on high-confidence drops). |
| `PP_RETRY_ROUTER_SHADOW` | `0` | When `1`, logs "what would have happened" to `retry-router-shadow.jsonl` without changing behavior. Use this BEFORE enabling router. |
| `PP_RETRY_ROUTER_CANARY_PCT` | `0` | Percentage of sessions to receive the new routing. 10 = canary, 100 = full. Same session always lands in same bucket. |
| `PP_ESCALATION_STREAK_THRESHOLD` | `3` | Lens drop-streak threshold to promote to deep-mode investigation. Default 3 preserves v0.5.0 behavior. |
| `PP_KPI_ENABLE` | `0` | Emit per-cycle KPI rows to `kpi-cycle.jsonl`. Auto-enabled when router is on. |
| `PP_KPI_FORCE_DISABLE` | `0` | Kill switch — `1` suppresses KPI emit even when the router auto-enables it. Useful for byte-identity benchmarking. |
| `PP_OAR_ENABLE` | `0` | Enable SessionEnd hook to queue OAR-pending records (v0.5.2 prerequisite). |
| `PP_RETRY_HARD_CAP_ENABLE` | `0` | Enforce `PP_RETRY_USD_PER_CYCLE_HARD_CAP` via preflight reservation. With router on, prevents any single cycle from blowing past the cap. |
| `PP_RETRY_USD_PER_CYCLE_HARD_CAP` | `0.05` | USD ceiling for retry spend within one cycle. Once a cycle's reserved retries would exceed this, further retries are skipped (verdict stays DROP). |
| `PP_RETRY_MODEL_HIGH` | `gpt-5` | Model used when `pp_retry_confidence` says HIGH. Premium tier. |
| `PP_RETRY_MODEL_LOW` | `gpt-5-mini` | Model used when `pp_retry_confidence` says LOW. Cheap tier — the savings lever. |
| `PP_RETRY_MODEL` | (unset) | Operator override — pins ALL router retries to this model and excludes the cycle from SLO evaluation. Use for sticky experiments. |
| `PP_RETRY_SLO_WINDOW_HOURS` | `24` | Rolling window over which auto-rollback computes p95 of `retry_usd`. |
| `PP_RETRY_SLO_P95_CAP_USD` | `0.030` | p95 retry-USD that, if exceeded, engages auto-rollback. |
| `PP_RETRY_SLO_MIN_SAMPLES` | `40` | Minimum eligible cycles in the window before auto-rollback can engage. Anti-flap floor (bumped from 20 in R13). |
| `PP_RETRY_BACKOFF_INITIAL_HOURS` | `24` | First-tier rollback duration. |
| `PP_RETRY_BACKOFF_REPEAT_HOURS` | `72` | Second-tier rollback duration. Triggered when `disable_count`=1. |
| `PP_RETRY_BACKOFF_MAX_HOURS` | `168` | Third-and-beyond tier rollback duration. `polymath retry-router clear-flag` resets the tier to first. |
| `PP_RETRY_CANARY_SALT` | `pp-canary-v1` | Salt for the canary bucket hash. Rotate to re-shuffle which sessions are in the canary cohort. |
| `PP_RETRY_CANARY_GO_PCT` | `20` | Minimum projected-savings percentage that `polymath retry-router shadow-summary` will recommend advancing to canary. |
| `PP_LOG_MAX_BYTES` | `10485760` | Per-file size cap before JSONL telemetry logs rotate (file → file.1, single retention slot). |
| `PP_LOG_MAX_AGE_DAYS` | `30` | Soft hint for downstream pruners — telemetry older than this is considered stale (not enforced by `_pp_rotate_jsonl`). |

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
| `PP_CACHE_DIR` | `~/.claude/cache` | Where per-cycle observations, budget tracker, and metrics.jsonl live. Cache files are mode `600`, parent dir `700`, since v0.4.2. Run `polymath cache list` to inspect, `polymath cache clear` to remediate lax-mode legacy files. |
| `PP_STATE_DIR` | `~/.claude/pair-polymath` | Where user-supplied lenses, prompts, and `user.env` are read from. |

### Cache layout (v0.4.2+)

| File pattern | What it holds | Lifetime |
|---|---|---|
| `cc-tips-<16hex>.txt` | LLM-personalized tip rotation, **scoped to one project** (sha256 of git-toplevel or cwd). Project A's tips never leak into project B. | 30 min |
| `cc-monitor-<session>-<lens>.txt` | One lens observation per session/lens. Session-scoped, id-keyed (reordering lenses won't serve stale observations under the wrong identity). | 30 min |
| `cc-monitor-injected-{hash,time}-*.txt` | Per-lens idempotency state for the inject hook. | session lifetime |
| `cc-monitor-budget-<YYYYMMDD>.txt` | Daily LLM call counter; the daily cap accounting. **Never auto-deleted** (resets at local midnight via new file). | 1 day |
| `last-cycle-payload.json` | Per-cycle privacy log: what was sent to LLMs (byte counts + 500-char previews). | 1 cycle |

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
