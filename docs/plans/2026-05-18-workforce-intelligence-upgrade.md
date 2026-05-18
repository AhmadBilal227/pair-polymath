# Pair Polymath Workforce Intelligence Upgrade Plan

Date: 2026-05-18

Status: planning input. This is not a locked implementation spec yet.

## Objective

Raise the intelligence of the lens workforce by improving the prompt contracts, the eval harness, and the feedback loop that decides which lenses are useful. Do this before building persistent dynamic workforce mutation.

The product goal is simple: Pair Polymath should interrupt less often, but when it does interrupt, the observation should be better grounded, better timed, and more likely to change what Claude or the operator does next.

## Research Signals Applied

The external research and docs converge on six durable principles:

1. Prompt changes must be eval-driven. Establish success criteria and representative tests before tuning prompts.
2. Prompts need crisp structure: trusted instructions, untrusted context, examples, output contract, and self-check criteria should be separated consistently.
3. Agent quality needs trace-level evaluation, not just final-output grading, because routing, tool selection, guardrails, and handoffs can fail before the final response exists.
4. LLM judges are useful but must be calibrated against human labels and checked for bias. Percent agreement alone is not enough.
5. Prompt optimization works best when prompts are treated as versioned program components with metrics, datasets, and rollback.
6. Reflection can improve future agent behavior, but Pair Polymath should store reflection as operator-reviewable lessons and candidate prompt changes, not as automatic prompt mutation.

## Current System Map

Current intelligence surfaces:

- `prompts/analyst-primary.md`: one-shot lens prompt with strict `HAT: hook|||body` output.
- `prompts/router.md`: meta-lens selecting 1 to `PP_ROUTER_MAX` lenses from deterministic router signals.
- `prompts/critique.md`: post-analyst pass/drop gate with grounding and redundancy checks.
- `prompts/analyst-retry.md`: second-attempt prompt after critique drop.
- `prompts/pattern-extraction.md` and `lib/memory/patterns.sh`: recurring observation clustering.
- `lib/router-signals.sh`: deterministic phase/confidence/outcome/tone feature extraction.
- `lib/router.sh`: LLM router, eligibility gates, surprise inject, fail-open behavior.
- `lib/oar.sh`: observation-to-action-rate labeling.
- `test/eval/run-eval.sh`: fixture replay harness.
- `test/eval/score.sh`: LLM judge over observations and goldens.
- `test/eval/calibrate-judge.sh`: human-vs-judge calibration report.

Main gaps:

- Prompt versions are not first-class metadata in eval/OAR rows.
- Trace evaluation is partial: we score observations, but not the full decision path from context bundle to router pick to critique verdict to OAR outcome.
- Judge verdict classes are too coarse for root-cause repair.
- Goldens are sparse and missing-golden cases are unscored.
- Pattern extraction finds recurring themes but does not produce a controlled lesson/proposal queue.
- Prompt tuning is manual; there is no safe candidate-generation, A/B, rollback, or acceptance workflow.
- Workforce mutation is already envisioned, but should remain gated until OAR and eval data are strong enough.

## North-Star Architecture

Build an intelligence flywheel:

```
session trace
  -> deterministic extraction
  -> router and lens run
  -> critique and safety gates
  -> observation shown or dropped
  -> OAR outcome
  -> eval trace record
  -> failure analysis
  -> prompt/lens/router proposal
  -> offline A/B eval
  -> operator acceptance
  -> versioned rollout
```

No automatic mutation in the next slice. The system may propose prompt, router, lens, and workforce changes; the operator applies them.

## Release Slices

### v0.5.4 - Prompt Contracts and Trace Capture

Goal: make every intelligence decision reproducible.

Implementation:

- Add a prompt manifest for each built-in prompt:
  - id
  - version
  - owner module
  - input variables
  - output schema
  - security boundary
  - eval suites that cover it
- Add `polymath prompts list|show|lint`.
- Add `lib/prompt-contract.sh` to validate:
  - required placeholders exist
  - unknown placeholders are rejected
  - output contract is declared
  - untrusted data fence exists where needed
  - prompt version is emitted into trace metadata
- Extend statusline trace capture to write a bounded JSONL row per cycle:
  - prompt versions
  - router signals
  - enabled lenses
  - picked lenses
  - lens output hashes
  - critique verdict and reason class
  - shown observation id
  - cost/latency counters

Tests:

- `test/prompt-contract.bats`
- trace schema tests
- no raw unredacted transcript in trace rows
- existing `bats test`

Gate:

- All prompts lint clean.
- Eval traces can reproduce the same prompt/context bundle shape without calling the live hook.

### v0.5.5 - Trace-Level Eval Harness

Goal: evaluate the whole intelligence path, not just observation text.

Implementation:

- Extend `test/eval/run-eval.sh` to emit `trace.jsonl`.
- Add `test/eval/trace-score.sh` with verdict classes:
  - `router_miss`
  - `lens_undertrigger`
  - `lens_overtrigger`
  - `weak_observation`
  - `grounding_fail`
  - `critique_false_drop`
  - `critique_false_pass`
  - `retry_recovered`
  - `golden_missing`
- Add fixture-level expected router targets and risk classes.
- Add coverage floors:
  - router target recall by risk class
  - security/data-loss hallucination zero tolerance
  - no critical risk class can go fully silent across a fixture suite
- Add an eval report that compares prompt versions, not just current vs baseline.

Tests:

- trace scorer unit tests with fake traces
- fixture tests for router miss and false pass
- regression tests for missing goldens being reported, not silently ignored

Gate:

- Router target recall >= configured floor on canonical fixtures.
- Hallucination rate does not rise versus current baseline.
- Missing-golden count is visible in reports.

### v0.5.6 - Judge Calibration and Rubric Hardening

Goal: make the judge trustworthy enough to guide prompt changes.

Implementation:

- Convert judge output to structured JSON:
  - verdict
  - reason_class
  - confidence
  - cited_evidence
- Add a fixed calibration pack under `test/eval/calibration/`.
- Add `polymath eval calibrate --csv ... --report ...`.
- Track more than agreement rate:
  - confusion matrix
  - per-class precision/recall where labels exist
  - Cohen kappa when enough labels exist
  - judge leniency/strictness drift over time
- Add parity guard so `score.sh` and `calibrate-judge.sh` cannot silently diverge in judge prompt text.

Tests:

- calibration CSV fixtures
- malformed judge JSON fallback
- prompt parity/checksum test
- injection attempts inside observation/golden cells

Gate:

- Calibration report passes a minimum agreement/kappa threshold before judge metrics can block merges.
- If calibration fails, eval reports become advisory only.

### v0.5.7 - Prompt Improvement Flywheel

Goal: safely improve prompts from real failures.

Implementation:

- Add `polymath prompts propose <prompt-id>`:
  - reads recent failed traces
  - summarizes failure modes
  - generates a candidate prompt patch
  - stores proposal under state dir, not in repo
- Add `polymath prompts eval <proposal-id>`:
  - runs proposal against selected fixtures
  - reports deltas for useful, hallucinated, obvious, missed_better, router recall, and cost
- Add `polymath prompts accept <proposal-id>`:
  - applies the proposal only after eval report exists
  - records provenance and rollback metadata
- Add `polymath prompts rollback <prompt-id> <version>`.
- Keep runtime Bash 3.2. Any DSPy-style optimizer should be an optional offline lab later, not a dependency of the hook path.

Tests:

- proposal storage and rollback
- eval must exist before accept
- proposal cannot edit files outside prompt override scope
- prompt candidate cannot remove security-boundary text unless the eval suite explicitly passes injection fixtures

Gate:

- Candidate prompt must improve at least one target metric without regressing any protected metric.
- Security-boundary fixtures are mandatory for every accepted prompt proposal.

### v0.5.8 - Lesson Queue and Lens Learning

Goal: turn OAR and dismissals into controlled learning.

Implementation:

- Add `polymath lessons list|show|accept|dismiss`.
- Generate lessons from:
  - acted observations
  - pushed-back observations
  - repeated critique drops
  - repeated user dismissals
  - recurring patterns
- Lesson schema:
  - id
  - source observation ids
  - affected lens or router
  - proposed constraint or example
  - confidence
  - expiry/TTL
  - status
- Accepted lessons become bounded prompt context:
  - never raw transcript
  - never raw test output
  - no memory bodies copied verbatim
  - only concise, redacted, operator-approved constraints

Tests:

- lesson generation from fixture OAR rows
- accepted lesson injection
- TTL expiry
- project identity isolation
- redaction and injection defenses

Gate:

- Accepted lessons improve second-run fixture behavior without increasing noise.
- No lesson crosses project identity boundaries.

### v0.6 - Workforce Proposals

Goal: start workforce intelligence without automatic workforce mutation.

Implementation:

- Add `polymath agents propose` using trace/OAR/lesson data.
- Proposal types:
  - create candidate agent
  - promote lens
  - demote lens
  - pause lens with TTL
  - add temporary session-scoped reviewer
  - adjust prompt
- Require evidence:
  - minimum OAR sample count
  - Wilson lower-bound threshold for acted rate
  - false-positive ceiling
  - recent coverage data
- Add coverage monitor:
  - critical risk classes keep a shadow canary floor
  - demoted/paused states have TTL
  - doctor flags silent coverage regression

Gate:

- No persistent workforce mutation without explicit operator command.
- No auto-fire, auto-promote, or auto-prompt-rewrite.
- OAR fidelity gate must pass first.

## Prompt Engineering Changes

Apply these to each prompt only through the eval-driven slices above:

- Use consistent sections:
  - role
  - trusted task
  - untrusted inputs
  - available evidence
  - decision criteria
  - output contract
  - examples
  - final self-check
- Make the analyst prompt less one-shot by adding explicit internal checks:
  - Is this grounded in visible facts?
  - Is it different from recent observations?
  - Does it change what Claude should do next?
  - Is SILENT better than weak advice?
- Add 3 to 5 compact examples per high-value lens, with edge cases.
- Split router prompt examples by phase:
  - debugging
  - planning
  - implementation
  - verification
  - stuck loop
- Give critique a closed reason taxonomy so dropped observations create training signal.
- Keep output terse for runtime, but keep trace metadata rich for offline evals.

## Harness Engineering Changes

Add these metrics to eval reports:

- observation usefulness
- hallucination rate
- obvious/noise rate
- missed-better rate
- router target recall
- router over-selection
- critique false-pass and false-drop rate
- retry recovery rate
- OAR acted/reference/pushed-back/ignored rates
- protected risk coverage
- cost per useful observation
- latency per cycle
- prompt-version deltas

Add these fixture classes:

- normal implementation
- failing tests
- repeated edit loop
- security-sensitive diff
- database/schema work
- user correction after wrong assumption
- stale memory/dismissal
- prompt-injection text in source/test output
- context pressure and budget pressure
- installer/onboarding workflows

## Root-Cause Repair Rules

When a metric fails:

- `router_miss`: fix `lib/router-signals.sh`, `prompts/router.md`, or lens eligibility. Do not widen all lens firing as the first response.
- `grounding_fail`: fix `lib/grounding.sh`, citation allowlists, or analyst grounding instructions.
- `critique_false_drop`: fix `prompts/critique.md` and add a golden trace.
- `weak_observation`: improve lens examples or lens-specific focus, not the global analyst prompt first.
- `hallucination`: tighten evidence contract and add injection/grounding fixture before any style tuning.
- `low_acted_rate`: inspect OAR quality first; do not demote a lens until label fidelity is proven.

## Commit Sequence

1. Spec/docs for this intelligence plan.
2. Prompt manifests and `polymath prompts list|show|lint`.
3. Trace schema and bounded trace writer.
4. Eval harness trace capture and trace scorer.
5. Judge rubric JSON, calibration pack, and parity guard.
6. Prompt proposal/eval/accept/rollback workflow.
7. Lesson queue and accepted-lesson injection.
8. Workforce proposal commands and coverage monitor.

## Non-Goals For The Next Slice

- No Python rewrite of runtime hooks.
- No automatic prompt mutation.
- No automatic hire/fire/promote/demote.
- No raw transcript or raw test output in fun mode, lessons, or long-term prompt memory.
- No internet access for runtime analysts unless the operator later explicitly changes the product decision.

## Immediate Next Step

Draft and implement v0.5.4 as a locked spec:

- prompt manifest format
- prompt linter
- trace JSONL schema
- trace privacy rules
- initial trace tests
- docs updates for prompt versioning and eval reproducibility

