# Data Quality Before Self-Improvement

Pair Polymath must not promote, fire, or mutate lenses from noisy data. This
release adds the minimum gates needed before any workforce self-improvement
loop can be trusted.

## Gates

1. Project identity is mandatory for new live telemetry.
   - New OAR pending/labeled rows, router metrics, cost metrics, trace rows,
     dismiss/cache identity, and history filtering use the same local project
     identity helper.
   - `polymath history` reports the current project by default.
   - `polymath history --all-projects` is required for cross-project audits.
   - `polymath doctor` warns when live pending rows or v2 labeled rows are
     missing identity or belong to another project.

2. Historical evidence is bootstrap-only.
   - `polymath oar bootstrap scan` reads Claude session JSONL logs and writes
     `$PP_STATE_DIR/oar/bootstrap-labeled.jsonl`.
   - Bootstrap rows carry confidence tiers such as `session_log_inferred`,
     `legacy_inferred`, and `unlabelable`.
   - Bootstrap rows never merge into canonical `oar-labeled.jsonl`.
   - Bootstrap evidence can inform reports and proposals, but not automatic
     promotion/firing.

3. Usefulness scoring is deterministic and privacy bounded.
   - `polymath insights score --window 7d` scores live OAR plus bootstrap rows.
   - Stored score rows contain hashes, redacted snippets, feature flags, and
     evidence references.
   - Score rows do not duplicate raw advisory bodies, raw transcripts, raw test
     output, or payload previews.

4. Prompt injection is throttled before Claude sees it.
   - UserPromptSubmit injects at most 3 ranked advisory groups by default.
   - Repeated topic hashes cool down for 30 minutes.
   - Similar observations are grouped as quorum notes.
   - Protected security/data-loss/cost classes can bypass normal cooldown only
     when grounded; suppressed protected notes are recorded in telemetry.

## Commands

```bash
polymath history --json
polymath history --all-projects --json
polymath oar bootstrap scan
polymath oar bootstrap report --json
polymath insights score --window 7d --json
polymath doctor
```

## Self-Improvement Rule

No automatic lens roster change should use:

- rows without current project identity,
- bootstrap rows as decision-grade outcomes,
- noisy-looking insights without operator review,
- protected-class suppressions that lack grounding,
- data from another project unless the operator explicitly requested
  `--all-projects`.
