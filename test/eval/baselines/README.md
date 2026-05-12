# Pair Polymath — eval baselines

This directory stores frozen baseline measurements taken at significant points in the v0.3 intelligence roadmap. Each subdirectory is one measured run, named after the phase it represents.

Phase 2.x PRs compare their measured deltas against the most recent baseline; the comparison is what gates merge (see `docs/eval-harness.md`).

## Current baselines

### `post-phase-2.1/`

Measured against `main @ 0629e74` (Phase 2.1 lens personalities merged). Single fixture: `session-01` (n+1 Prisma query in `handlers/users.ts`).

**Headline result: 0 / 7 format-compliant observations.**

```json
{
  "run_ts": "20260512T063620Z",
  "fixtures_processed": 1,
  "total_observations": 0
}
```

The cycle ran (1 planner + 7 analysts = 8 LLM calls, $0.014 billed), but all 7 analyst responses failed the validation regex `^[A-Z]+: .{20,}\|\|\|.{40,}$` and the lens cache files were left empty.

**Root cause analysis:** Manual probing during baseline establishment showed the model's actual outputs follow a `HAT|||body` form (no `: hook` segment) about 30-50% of the time under the new Phase 2.1 prompts — the longer lens-personality context appears to push gpt-5-mini off the strict `HAT: hook|||body` format. Phase 2.1's worked examples DO show the correct format, but the SILENT-trigger example mixed in (added in R2 fix) may be confusing the model.

**Tracked as:** issue #42 (filed as part of this PR). Hotfix Phase 2.1.1 will either tighten the format guidance in `prompts/analyst-primary.md` OR loosen the validation regex in `bin/statusline.sh` to accept both `HAT: hook|||body` AND `HAT|||hook|||body` forms.

**Next baseline:** `post-phase-2.1.1/` will be captured after the hotfix lands. That measurement establishes the real pre-Phase-2.2 baseline.

## How to re-measure

```bash
# Replay fixtures (calls real LLM)
bash test/eval/run-eval.sh --all

# Score against goldens (calls real LLM, --cheap = gpt-5-mini)
bash test/eval/score.sh --cheap

# The latest run lives at test/eval/runs/<timestamp>/
# Copy to baselines/ when locking a phase boundary:
cp -r test/eval/runs/<timestamp> test/eval/baselines/post-phase-X.Y/
```

## Cost notes

Per fixture per run (with 1 planner + 7 analysts + critique if any):
- gpt-5-mini: ~$0.014 per run-eval cycle, ~$0.007 per score pass
- gpt-5: ~$0.18 per run-eval cycle, ~$0.09 per score pass

10-fixture baseline on gpt-5-mini: ~$0.21 round-trip. Cheap enough to re-baseline freely.
