# Pair Polymath — Memory Architecture (v0.3 Phase 2.3)

Pair Polymath builds **per-project memory** that persists what the analyst lenses observe over time, then surfaces the most relevant past observations into each new cycle's prompt. Default is OFF — set `PP_MEMORY_ENABLE=1` to activate.

## 1. What is memory?

Inspired by ACT-R's base-level activation model. The memory subsystem records every analyst observation, scores it on a decaying-with-reinforcement curve, and retrieves the top-K for injection into the next cycle.

The long-term vision is **5 tiers**:

| Tier | Status | Description |
|------|--------|-------------|
| 1. Per-cycle scratchpad | shipped pre-2.3 | The transcript-tail-and-history block already used by analyst-primary |
| 2. Project memory | **shipped in 2.3** | SQLite per-project store + FTS5 hybrid retrieval + activation scoring |
| 3. Pattern extraction | **shipped in 2.3** | LLM clusters recent observations into recurring themes (patterns.jsonl) |
| 4. Cross-project | v0.4 | Embeddings + sqlite-vec; project-portable insights |
| 5. Community tier | v0.5 | Opt-in anonymous pattern sharing |

v0.3 covers tier 2 + 3. Off-by-default until the eval gate (`test/eval/run-memory-gate.sh`) passes against labeled goldens.

## 2. How it works

```
                                 ┌──────────────────────┐
  cycle start  ───────────────► │ pp_memory_top_k      │ ──► MEMORY_BLOCK ──► analyst prompt
                                 │ (hybrid BM25 + acti) │
                                 └──────────────────────┘
                                                                       │
                                                                       ▼
                                                          ┌──────────────────────┐
  lens observation ──────────► │ pp_memory_insert     │ (per-lens)
                                 │ (redact → store)     │
                                 └──────────────────────┘
                                                                       │
                                                                       ▼
                                                          ┌──────────────────────┐
                                                          │ run_signals_post_… │
                                                          │ retention / file-edit│
                                                          │ commit-mention / test│
                                                          └──────────────────────┘
                                                                       │
                                                  every Nth cycle (default 12)
                                                                       ▼
                              ┌──────────────────────────────────────────────────────┐
                              │ pp_memory_recompute_scores  →  pp_memory_evict      │
                              │                                                       │
                              │ pp_memory_extract_patterns  (cluster recent → JSONL) │
                              └──────────────────────────────────────────────────────┘
```

### Activation formula (ACT-R-inspired heuristic)

```
activation = ln(use_count + 1)
           − decay_per_day × days_since_last_seen
           + 0.6 × act_count
           + 0.4 × signal_retention
```

A fresh observation with `use_count=1, days=0` scores ~0.693. One week of inactivity with no further use brings it to ~−2.81 — well below any new entry. Tuned for the default `PP_MEMORY_DECAY_PER_DAY=0.5`.

The other three reinforcement signals (`signal_file_edit`, `signal_commit_mention`, `signal_test_flip`) are stored as binary one-shots and reserved for a v0.4 weight sweep — wiring them into the activation formula without first calibrating multipliers would shift retrieval ordering on every existing row.

### Hybrid retrieval (BM25 + activation)

The default top-K query is recency-biased (`activation_score DESC`). When a query string is supplied (synthesized from cwd + recent files + recent commits), retrieval mixes in FTS5 BM25 relevance:

```
hybrid_score = activation_score + PP_MEMORY_RETRIEVAL_ALPHA × normalized_bm25
```

BM25 is normalized by max-relevance so it stays on the same [0,1] scale as activation. Defaults to α=1.0.

### Pattern extraction

Every `PP_MEMORY_MAINTENANCE_EVERY_N` cycles (default 12 = once per hour at 5-minute cycles), the maintenance step:

1. Recomputes `activation_score` for every row (one SQL statement, atomic, under lock).
2. Evicts the bottom-K rows by activation_score IF the DB has exceeded `PP_MEMORY_MAX_BYTES`. Eviction is summary-first: an LLM produces ONE pattern entry capturing the evicted cohort's gist before the rows are deleted. If the LLM can't summarize, eviction is aborted (no data loss).
3. Runs `pp_memory_extract_patterns`: pulls the last `PP_MEMORY_PATTERN_BATCH_SIZE` observations (default 200), asks an LLM to find 0–5 recurring themes, appends each as one JSONL line to `$proj_dir/patterns.jsonl`. The JSONL is capped at `PP_MEMORY_PATTERNS_MAX` lines (default 1000) and rotated FIFO when exceeded.

## 3. Privacy model

- **Per-machine random salt** (`$PP_MEMORY_DIR/.salt`, 0600) ensures the project hash cannot be guessed from `git remote.origin.url` alone. Salt survives reinstall and is the same across all projects on this machine.
- **Project identity hash** = `sha1(salt || identity)[0:16]` where `identity` is `git remote.origin.url` (preferred) or `realpath(cwd)` (fallback).
- **File permissions**: `$PP_MEMORY_DIR/projects/<hash>/` is `0700`, all DB/JSONL files are `0600`.
- **Redaction at store time** (`PP_MEMORY_REDACT=1`, default on): every body run through `pp_memory_redact_body` before insertion. Patterns redacted: OpenAI `sk-…`, GitHub `ghp_…`/`github_pat_…`, Bearer tokens, AWS `AKIA…`, Slack `xox…`, emails, Stripe `pk/sk/rk_live/test_…`, JWTs, DB URIs, `.env` file references.
- **Redaction at inject time** (defense-in-depth, per ai-engineer R1 §5): every body re-redacted right before it lands in `MEMORY_BLOCK`. Catches observations that were stored under an older redaction list before the user upgraded.
- **Containment**: cited paths must resolve inside the cwd via `pp_contain_path` (lib/grounding.sh). Paths outside the repo are rejected silently at store time and at signal-eval time.

## 4. Configuration

Every knob is overrideable in `~/.claude/pair-polymath/config/user.env`.

| Variable | Default | Effect |
|---|---|---|
| `PP_MEMORY_ENABLE` | `0` | Master toggle. When 0 the cycle path is byte-identical to pre-2.3. |
| `PP_MEMORY_DIR` | `$CLAUDE_DIR/pair-polymath/memory` | Storage root (project subdirs live under `$PP_MEMORY_DIR/projects/<hash>/`). |
| `PP_MEMORY_REDACT` | `1` | Apply secret-pattern redaction at store AND inject time. |
| `PP_MEMORY_ACTIVATION_K` | `15` | Top-K rows pulled per cycle. |
| `PP_MEMORY_INJECT_BODY_CHARS` | `240` | Truncate each injected body to this many chars. |
| `PP_MEMORY_RETRIEVAL_ALPHA` | `1.0` | Hybrid weight: activation + α × normalized_bm25. |
| `PP_MEMORY_DECAY_PER_DAY` | `0.5` | Base-level activation decay (k × days_old). |
| `PP_MEMORY_MAX_BYTES` | `104857600` | Eviction threshold (100 MiB). |
| `PP_MEMORY_EVICT_BATCH_SIZE` | `50` | Rows deleted per eviction sweep. |
| `PP_MEMORY_PATTERN_BATCH_SIZE` | `200` | Recent obs fed to pattern extractor. |
| `PP_MEMORY_PATTERNS_MAX` | `1000` | Cap on `patterns.jsonl` line count (FIFO rotation when exceeded). |
| `PP_MEMORY_MAINTENANCE_EVERY_N` | `12` | Cycles between maintenance runs (12 × 5min = 1h). |
| `PP_MEMORY_LLM_BIN` | (unset) | Override LLM binary for patterns + eviction (test/fixture path). |
| `PP_MEMORY_LLM_MODEL` | `gpt-5-mini` | Model used when calling `llm` for patterns/eviction. |
| `PP_MEMORY_LLM_TIMEOUT_S` | `60` | Timeout for memory LLM calls. |
| `PP_MEMORY_LOCK_TIMEOUT_S` | `30` | Wait time before giving up on maintenance lock. |
| `PP_MEMORY_LOCK_STALE_S` | `300` | Stale-lock takeover threshold (orphaned lockdir age). |

## 5. CLI reference

```
polymath memory status          DB path, row count, size, top-5 by activation
polymath memory recompute       Manual activation_score recompute (under lock)
polymath memory evict           Manual eviction sweep (LLM summary required)
polymath memory patterns        Show last 10 extracted patterns (most recent first)
polymath memory clear --yes     Wipe all memory for the current project
polymath memory enable          Set PP_MEMORY_ENABLE=1 in user.env
polymath memory disable         Set PP_MEMORY_ENABLE=0 in user.env
```

Override active project: `PP_MEMORY_CLI_CWD=/path/to/repo polymath memory status`.

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `pp_memory_with_lock: timeout waiting on .maint.lock` | A previous maintenance run crashed and left a stale lockdir, but it's still within the stale-takeover window. | Wait `PP_MEMORY_LOCK_STALE_S` seconds (default 5 min) — takeover happens automatically. To force: `rm -rf $PP_MEMORY_DIR/projects/<hash>/.maint.lock`. |
| `polymath memory status` shows `(not yet initialized)` after enabling | Memory was enabled but no cycle has run yet, or the cycle ran in a different cwd. | Trigger one statusline cycle in the target repo; verify with `polymath memory status` from the same cwd. |
| DB grows past `PP_MEMORY_MAX_BYTES` and eviction doesn't fire | The LLM eviction-summary call failed (no key, network down, fixture missing). Eviction is aborted on summary failure rather than silently losing data. | Check `stderr` for "summary failed; aborting eviction"; resolve the LLM connectivity issue; eviction retries automatically next maintenance window. |
| `pp_memory_top_k` returns `[]` with a non-empty DB | Query string after sanitization was empty (e.g. all punctuation). Falls back to pure activation ranking — should still return rows. If empty here, the DB really is empty. | Check `polymath memory status`. |
| Phantom growth past cap | Eviction failed enough times that the DB grew unboundedly. Look for "eviction did NOT complete" in stderr. | Manually invoke `polymath memory evict` after fixing the LLM issue, or run `polymath memory clear --yes` to reset. |

## 7. v0.4 roadmap

- **sqlite-vec embeddings**: add a vector column for semantic top-K, blend in alongside BM25 + activation.
- **Symbol-touch signal**: scan recent edits for added/removed function names; reinforce obs that cited symbols entering/leaving the codebase.
- **Cross-project tier**: project-portable patterns surfaced by user_id-anchored salt rotation.
- **Community tier**: opt-in pattern federation across machines.
- **Activation weight sweep**: calibrate multipliers for `signal_file_edit`, `signal_commit_mention`, `signal_test_flip` against the labeled eval set (gated until goldens exist).

## 8. Eval gate

`test/eval/run-memory-gate.sh` runs the existing eval suite three times:

1. `PP_MEMORY_ENABLE=0` (baseline)
2. `PP_MEMORY_ENABLE=1`, fresh DB (cold)
3. `PP_MEMORY_ENABLE=1`, pre-populated DB (warm)

PASS criteria (when labeled goldens exist):
- warm `useful%` ≥ baseline `useful%` + 5pp
- warm `hallucinated%` ≤ baseline `hallucinated%`
- cycle latency p50/p99 ≤ baseline × 1.10
- off-mode output byte-identical to pre-2.3 baseline

**Status as of Task D ship:** harness present + `--dry-mode` validated, **labeled goldens not yet recorded → real PASS/FAIL pending**. The infrastructure works; the next step is to record useful%/hallucinated% goldens against the v0.2 eval fixtures and re-run with `--no-dry`.

Run it: `test/eval/run-memory-gate.sh --dry-mode`.
