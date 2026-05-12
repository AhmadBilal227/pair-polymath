# Memory Architecture — Task B/C/D Handoff

Compact context for subagents picking up Tasks B, C, D. Read this BEFORE the main plan (`2026-05-12-memory-architecture.md`) — this lists what's already done, what's locked in, and the bug classes to avoid.

## Branch state

- **Branch:** `feat/memory-architecture`
- **HEAD:** `0750269` ("fix(memory): R2 Task A — 9 ship-blocking issues from Ralph review")
- **Worktree:** `/tmp/memory-arch`
- **Origin:** pushed
- **Bats:** 34 in `test/memory/`, full suite 315/315

## Task A is done — what you can rely on

### Files already in lib/memory/

| File | Functions exported | Notes |
|---|---|---|
| `schema.sh` | `pp_memory_get_salt`, `pp_memory_project_hash`, `pp_memory_project_dir`, `pp_memory_db_init`, `pp_memory_db_migrate` | Per-machine salted hash; SQLite WAL DDL with `PRAGMA user_version = 1`; migration stub ready for v0.4 |
| `lock.sh` | `pp_memory_lock`, `pp_memory_unlock`, `pp_memory_with_lock` | Signature: `pp_memory_with_lock PROJ_DIR FUNC [ARGS...]` — **NO eval**, calls `"$@"` directly. Stale takeover only if `stat` returned a parseable mtime. |
| `redact.sh` | `pp_memory_redact_body`, `pp_memory_redact_path` | Patterns: OpenAI `sk-*`, Bearer, ghp_/github_pat_, AKIA, Slack `xox*`, `.env` (path-anchored), email, Stripe, JWT, DB-URIs. Path validation via `pp_contain_path` from grounding.sh. |

### SQLite schema (already created by `pp_memory_db_init`)

```sql
CREATE TABLE observations (
  obs_id              TEXT PRIMARY KEY,
  ts                  TEXT NOT NULL,
  schema_version      TEXT NOT NULL,
  lens_id             TEXT NOT NULL,
  topic, hook, body   TEXT,
  cited_paths         TEXT,   -- JSON-encoded array
  cited_symbols       TEXT,   -- JSON-encoded array
  project_hash        TEXT,
  session_id          TEXT,
  signal_retention    INTEGER DEFAULT 0,
  signal_file_edit    INTEGER DEFAULT 0,
  signal_commit_mention INTEGER DEFAULT 0,
  signal_test_flip    INTEGER DEFAULT 0,
  signal_symbol_touch INTEGER DEFAULT 0,   -- reserved; implementation deferred to v0.4
  use_count           INTEGER DEFAULT 1,
  act_count           INTEGER DEFAULT 0,
  last_seen_ts        TEXT NOT NULL,
  activation_score    REAL DEFAULT 1.0,
  embedding_id        TEXT,                 -- reserved for v0.4
  redacted            INTEGER DEFAULT 0
);
-- PRAGMA journal_mode = wal
-- PRAGMA user_version = 1
```

Plus `cycle_state(key TEXT PRIMARY KEY, value TEXT)` for cycle-counter etc.

## Locked-in conventions (don't relitigate)

1. **Storage substrate:** SQLite primary. JSONL only for `patterns.jsonl` (low write rate, append-only).
2. **Inserts:** jq-built JSON → SQLite `json_extract`. NOT sed-quoting. NOT `.parameter set` (it has quirks).
3. **Concurrency:** SQLite WAL handles single-statement / single-transaction. **`pp_memory_with_lock` wraps ANY multi-statement maintenance** (recompute, signals tagging, eviction, pattern extraction). Never call those without the lock.
4. **Cross-platform discipline:** `LC_ALL=C` inline per command (not file-global). BSD vs GNU stat: `stat -f %m FILE || stat -c %Y FILE`. BSD vs GNU date: `date -j -f` vs `date -d`. `shasum || sha1sum` fallback chain.
5. **Bash 3.2 portable:** no associative arrays, no `mapfile`, no `local -n`, no `${var,,}`.
6. **Privacy:** `chmod 700` on dirs, `chmod 600` on files. Memory bodies redacted at store time (`PP_MEMORY_REDACT=1` default).
7. **Schema versioning:** `PRAGMA user_version` + `pp_memory_db_migrate` stub. Future migrations land in `db_migrate` keyed by version number.

## Cross-platform bug classes already encountered (don't re-hit these)

| Class | Where it bit | Fix pattern |
|---|---|---|
| `local command=` shadows bash builtin `command -v` | PR #13 audit-log | Rename to `cmd` |
| `local path=` shadows zsh tied `$PATH` array | Task A R1 redact.sh | Rename to `pp_path` |
| `find $missing_path \| sort` aborts under `-eo pipefail` | PR #15 | `mkdir -p` first OR `find $path 2>/dev/null` |
| bats `run` stderr-merge differs across versions | PR #19, #36 | Use `bash -c 'cmd 2>/dev/null'` + file-grep instead of `$output` |
| BSD `tr ' ' '▰'` mangles emoji under `LC_ALL=C` | PR #25 | Scope `LC_ALL=C` per command, never file-global |
| `set -u` + `${!var-}` indirect lookup in `bash -c` makes vars empty cross-shell | PR #36 | Count files directly, don't source for var inspection |
| `stat -f %m` BSD-only, GNU stat treats `-f` as filesystem-info | PR #36 R3 | `pp_mtime()` helper in `bin/statusline.sh:25` |
| `eval` inside `_pp_run` runs cmd in parent shell — `exit 1` terminates probe | PR #25 R2 test fixture | Use `false` not `exit 1` in test fixtures |
| GitHub Push Protection rejects realistic secret-shaped fixtures | Task A R1 (Slack), R2 (Stripe) | Build at runtime: `key="$prefix_$body"` |
| Salt-file TOCTOU race on concurrent `get_salt` | Task A R2 | `mktemp + ln` atomic create-or-keep |
| `eval "$cmd"` invites future RCE even if currently safe | Task A R2 | Use function-name signature `cmd "$@"` |

## Phantom-Done countermeasure

A prior subagent reported "Done" but pushed zero changes. Verify EVERY task:

```bash
cd /tmp/memory-arch
git log --oneline -3              # commit must exist on the branch
git diff --stat origin/main..HEAD # files actually changed
git status                         # working tree clean
git status -sb                     # branch in sync with origin
```

If any of those show drift from the claimed Done state, the subagent's report is rejected and the task is re-dispatched.

## Ralph reviewer stack discipline

Every task ends with a **3-reviewer pass** (4 at PR level):

| Seat | Agent | Focus |
|---|---|---|
| Hostile code review | GPT-5.2 via `git diff ... \| llm -t review-code -m gpt-5.2 --no-stream` | bash portability, SQL safety, regex completeness, schema drift |
| Reproduce + verify | `debugging-toolkit:debugger` agent | actual probes against the live worktree, cross-platform repros, false-positive checks |
| LLM-application architecture | `llm-application-dev:ai-engineer` agent | schema completeness for future tasks, formula correctness, prompt-injection surface |
| (PR level only) General code review | `comprehensive-review:code-reviewer` agent | catch-all hostile read of the merged PR |

The ai-engineer seat catches things the other 3 miss: scorer prompt-injection (PR #36), retry-feedback lottery (PR #25), lens-personality bleed (PR #39), FTS5-vs-pure-recency retrieval (Task A R1).

## Tasks remaining

### Task B — Observation Store + Activation + Retrieval

**Files:** `lib/memory/store.sh`, `lib/memory/activation.sh`, `test/memory/store.bats`, `test/memory/activation.bats`

**Augmentation per ai-engineer R1 §9 (FTS5 retrieval):** the plan's Task B uses `pp_memory_top_k` with activation-only ranking. This is recency-biased — old-but-recently-touched dominates new-and-relevant. **Add FTS5 to Task B:**

- Extend `pp_memory_db_init` (in `schema.sh`) to also `CREATE VIRTUAL TABLE obs_fts USING fts5(hook, body, topic, content='observations', content_rowid='rowid')` + triggers (insert/update/delete keep FTS5 synced).
- New function `pp_memory_search_relevant CWD QUERY K` → top-K obs_ids by `bm25(obs_fts)` matched against QUERY.
- Modify `pp_memory_top_k` to **hybrid score**: when called with a context query, returns top-K by `activation_score + α × normalized_bm25_score`. When called without query, falls back to pure activation.

Without FTS5, retrieval can't be "relevant to current grounded context" — it's "stuff that fired recently." That's a known failure mode in the plan; folding the fix into Task B prevents it.

### Task C — 4 Windowed Signals + Maintenance Under Lock

**Files:** `lib/memory/signals.sh`, `test/memory/signals.bats`

**Signals (4, not 5):**
1. **retention** — same lens + same hook fires THIS cycle AND prior cycle (consecutive only, not global duplicate)
2. **file-edit** — observation cited path; that path appears in `git log --since=ts --until=ts+30m --name-only`
3. **commit-mention** — git commit since obs_ts mentions ≥4-char keyword from observation hook OR body (stopword-filtered)
4. **test-flip** — observation cited path; `LAST TEST/LINT RUN` cache shows ERROR + cited path in FAIL block + cache mtime within 30m of obs_ts

**Symbol-touch deferred to v0.4** (column reserved, signal not yet computed).

All taggers run under `pp_memory_with_lock` because they're read-modify-write on SQLite.

### Task D — Patterns + Eviction + Statusline Wiring + Eval Gates

**Files:** `lib/memory/patterns.sh`, `lib/memory/evict.sh`, `prompts/pattern-extraction.md`, `bin/statusline.sh`, `prompts/analyst-primary.md`, `lib/prompt-loader.sh`, `config/default.env`, `bin/polymath` (memory subcommand), `test/memory/integration.bats`, `docs/memory-architecture.md`.

**Eval merge gates (mandatory):**
- **PASS:** warm-start `useful%` ≥ +5pp absolute vs cold-start AND `hallucinated%` unchanged or down AND cycle latency ≤ +10% AND memory-off run identical to pre-2.3 baseline
- **FAIL:** any `useful%` drop, OR `hallucinated%` rise, OR latency rise > +15%, OR memory-off diverges from pre-2.3 baseline

PR is BLOCKED from merge if any FAIL condition triggers.

**Inject-time redaction** (ai-engineer R1 §5): in addition to store-time redaction, run `pp_memory_redact_body` again on the `activated_observations` block JUST BEFORE injecting into the analyst prompt. Catches v1-stored rows when the v1.1 redaction patterns evolve.

## v0.4 deferred (don't do in this PR)

- Real embeddings via `llm embed`
- `sqlite-vec` extension for vector similarity
- Symbol-touch signal (column reserved)
- User-tier memory (per-lens calibration across projects)
- Community memory (opt-in MCP server)
- Salt-portability across machines (design trade-off accepted)
