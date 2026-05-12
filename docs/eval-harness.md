# Pair Polymath — Eval Harness

The eval harness measures whether prompt / lens / critique changes actually
improve observation quality. Without it, every "I think this is sharper" is a
vibe check. With it, every PR can be gated by a measurable delta against the
v0.2 baseline.

Status: **Phase 1 scaffold landed.** One example fixture (`session-01`) ships
with the repo. The user (Ahmad) adds fixtures 02-10 from real dogfood
sessions in follow-up PRs to produce the locked baseline.

## Quick start

```bash
# Replay every fixture under test/eval/fixtures/ (skipping LLM calls)
bash test/eval/run-eval.sh --all --dry-run

# Score the latest run against the goldens. --offline skips the LLM scorer
# and emits a stub report; --cheap uses gpt-5-mini if you do want scoring.
bash test/eval/score.sh --offline

# Inspect the per-lens tallies
jq '.per_lens' test/eval/runs/latest/score-report.json   # 'latest' is a pointer file
```

## What `PP_EVAL_MODE=1` does to `bin/statusline.sh`

- Forces the cycle gate open (`is_active=1`, `parallel_age > interval`) so a
  single invocation runs ONE full cycle regardless of recency.
- Runs the analyst fan-out + critique cycle **synchronously** instead of
  fire-and-forget (so the caller sees the output of this cycle, not the
  previous cycle's cache).
- After the cycle completes, reads each lens's cache file and emits one
  line per lens to stdout in the format `LENS_ID|||TOPIC|||HOOK|||BODY`.
- Suppresses the normal statusline render and exits 0.

When `PP_EVAL_MODE` is unset (the normal case), the file behaves identically
to v0.2.0 — no eval-mode code path runs.

## Schema

### Observation row (one per lens, in `<fixture>.observations.txt`)

```
LENS_ID|||TOPIC|||HOOK|||BODY
```

- `LENS_ID` — uppercase id from `lenses/*.json` (e.g. `ENGINEERING`).
- `TOPIC` — the analyst's HAT (e.g. `ARCH`, `SEC`, `OPS`). Empty for SILENT.
- `HOOK` — 40-70 char attention fragment. Empty for SILENT.
- `BODY` — 80-180 char concrete observation with a next-step verb. Empty
  for SILENT.

Empty observation rows (`LENS_ID|||||||`) are valid signal — they mean the
lens ran but produced nothing scorable (SILENT, dropped, missing API key).

### Run summary (`run-summary.json`)

```json
{
  "run_ts": "20260512T031530Z",
  "fixtures_processed": 1,
  "errors_per_fixture": {"session-01": 0},
  "total_observations": 5,
  "dry_run": 0
}
```

### Score report (`score-report.json`)

```json
{
  "run_ts": "20260512T031530Z",
  "scored_at": "20260512T031555Z",
  "scorer_model": "gpt-5",
  "offline": 0,
  "fixtures": [
    {"name": "session-01",
     "lenses": {
       "ENGINEERING": {
         "verdict": "useful",
         "observation": "ARCH: ...|||...",
         "golden": "ARCH|||...|||..."
       }
     }}
  ],
  "per_lens": {
    "ENGINEERING": {
      "useful": 1, "obvious": 0, "hallucinated": 0,
      "missed-better": 0, "missing": 0, "unscored": 0
    }
  }
}
```

The four verdicts are produced by the LLM scorer:

- **useful** — the observation matches the angle of the golden ref, OR is a
  defensible alternative.
- **obvious** — the observation is trivial / low signal (e.g. "add tests").
- **hallucinated** — cites a file / symbol / fact not in the grounded input.
- **missed-better** — the golden ref captured something the model missed.

Plus two non-LLM verdicts:

- **missing** — the lens emitted no observation (SILENT or dropped without
  retry). Distinct from `obvious` because no LLM call was made.
- **unscored** — there's no golden file for this lens / fixture, OR
  `--offline` was passed. Not penalized in the aggregate.

## Adding a fixture

See [`test/eval/fixtures/README.md`](../test/eval/fixtures/README.md).

Short version:

```bash
mkdir test/eval/fixtures/session-NN
# input.json (use @TRANSCRIPT@ and @CWD@ placeholders)
# transcript.jsonl (small)
# cwd-state.txt (single file) OR cwd-state/ (directory)
# notes.md (which lens, what observation)

bash test/eval/run-eval.sh --fixture session-NN --dry-run
```

## Adding a golden ref

See [`test/eval/golden/README.md`](../test/eval/golden/README.md).

Short version: hand-write one line per lens in
`test/eval/golden/session-NN/<LENS_ID>.txt` matching the
`TOPIC|||hook|||body` shape.

You don't need a golden for every lens — only the ones you expect to fire on
this scenario. Lenses without a golden are `unscored` (not penalized).

## Interpreting a score report

For a single fixture, look at:

- **useful%** per lens — primary target metric. Phase 2 PRs gate on
  per-lens +10pp.
- **hallucinated%** — secondary. Phase 2.2 (deterministic citation check)
  is expected to drive this down. Phase 2.2 added explicit `valid_paths` +
  `valid_symbols` allowlists to the critique input (extracted in shell from
  the un-truncated grounded blob; see `lib/citations.sh`). The Phase 2.2 PR
  will commit the post-2.2 baseline showing the `hallucinated%` delta vs
  `post-phase-2.1.1`.
- **missing rate** — if SILENT is dominating, the analyst is failing to find
  signal in your fixtures. Either the fixtures are too thin or the lens
  prompts are over-conservative.

For multi-fixture runs, compare against `test/eval/baseline.json` (locked
in a follow-up PR once we have 10 fixtures × 7 lenses scored on the v0.2.0
main).

## When to update the baseline

- After a measured Phase 2 PR lands and the eval delta is +10pp useful% / no
  hallucination regression.
- After fixture set 02-10 lands.
- NEVER mid-PR. The baseline is a stable reference; updating it inside a PR
  that's trying to beat it defeats the gate.

Bump procedure (when authorized):

```bash
bash test/eval/run-eval.sh --all                    # not --dry-run
bash test/eval/score.sh                             # not --offline
cp test/eval/runs/<latest>/score-report.json test/eval/baseline.json
git add test/eval/baseline.json
git commit -m "eval: refresh baseline post-<change-description>"
```

## CI integration (deferred)

The eval bats suite (`test/eval/eval.bats`) runs under `--dry-run` /
`--offline` paths only, so it costs nothing to keep in CI. The real
scoring run is manual — gated by `OPENAI_API_KEY` availability and budget.

A future PR may add a "scheduled eval" GitHub Action that runs scoring
nightly against `main` and posts the delta to the issue tracker. Not now.

## Cost expectations

For 10 fixtures × 7 lenses = 70 observations to score, the LLM scorer
issues 70 short `gpt-5` calls (each ~300 in / ~5 out tokens). At public
gpt-5 pricing snapshots that's roughly $0.30-$0.50 per full scoring run.
`--cheap` swaps to `gpt-5-mini` and brings that to ~$0.05.

The cycle replay itself (the cost of running `bin/statusline.sh` once per
fixture) is one full Pair Polymath cycle per fixture: ~9 LLM calls
(planner + 7 analysts + critique). For 10 fixtures: ~90 calls,
gpt-5-mini-dominated, ~$0.10-$0.20 per full replay.

Total for a full eval run: under $1.
