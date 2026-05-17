# Cost Model

`polymath cost` shows estimated USD spend from `$PP_CACHE_DIR/metrics.jsonl` (default `$CLAUDE_DIR/cache/metrics.jsonl`). This document explains the math.

## Per-cycle formula

A full lens cycle makes up to 23 LLM calls in the worst case:

- 1 planner (`gpt-5-mini`)
- 7 analysts (`gpt-5-mini` per lens by default)
- 1 critique (`gpt-5`)
- \+ up to 7 retries (one per DROPped analyst, `gpt-5-mini`)
- \+ up to 7 escalation pre-investigations (one per lens with 3+ drop streak, `gpt-5-mini`)

Average cycle: closer to **9-12 calls**.

## USD math

For each call:

```
usd = (avg_input_tokens  / 1_000_000) × $ per 1M input
    + (avg_output_tokens / 1_000_000) × $ per 1M output
```

Avg tokens per call type (see `lib/metrics.sh` for current values):

| Call type | Input tokens | Output tokens | Model |
|---|---|---|---|
| planner | ~800 | ~50 | gpt-5-mini |
| analyst | ~2200 | ~180 | gpt-5-mini |
| critique | ~3500 | ~500 | gpt-5 |
| inv (escalation pre-investigation) | ~1500 | ~100 | gpt-5-mini |
| retry | ~2500 | ~180 | gpt-5-mini by default; cost-aware retry router can choose `PP_RETRY_MODEL_LOW` / `PP_RETRY_MODEL_HIGH` |

Prices (defaults in `config/default.env`; override via `user.env`):

| Model | Input $/M | Output $/M |
|---|---|---|
| gpt-5-mini | $0.25 | $2.00 |
| gpt-5 | $1.25 | $10.00 |
| gpt-5.5 | $2.50 | $15.00 |

## Why estimates can be off by 20-50%

- Real input size depends on grounded-facts string size (transcript tail + git status + one file), which varies wildly
- Real output size depends on the model's actual response (can be much longer or "SILENT")
- Prices drift; defaults reflect the v0.2 ship date

v0.3 plans real per-call `--usage` parsing via `llm --usage`, which gives exact token counts per call. For now: treat estimates as ±50%.

## When the daily cap kicks in

`PP_MAX_DAILY_CALLS=10000` (default) is a hard cap on **call count**, not USD. Enforced via the same atomic shared lock that backs `budget_reserve`. If reserving worst-case 23 calls would push the daily total over 10000, the cycle is skipped entirely.

To express a USD cap (v0.3 territory): a hook that reads `polymath cost --since 1d --json` and sets `PP_EXTERNAL_LLM=0` once total exceeds a threshold.
