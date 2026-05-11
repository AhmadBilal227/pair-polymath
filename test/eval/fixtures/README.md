# Eval fixtures

Each fixture is a directory `session-NN/` exercising a specific lens / scenario.
The driver (`test/eval/run-eval.sh`) replays each fixture through
`bin/statusline.sh` with `PP_EVAL_MODE=1` set, capturing per-lens observations.

## Schema

```
test/eval/fixtures/session-NN/
├── input.json       # Claude Code's statusline stdin format
├── transcript.jsonl # Synthetic Claude Code transcript snippet
├── cwd-state.txt    # Single-file fake project state (OR a cwd-state/ dir)
└── notes.md         # Which lens this exercises + the ideal observation
```

### `input.json`

A JSON object matching Claude Code's statusline input. Required keys:

- `session_id` — overridden by the driver to `fixture-<name>`, so this value
  is informational only.
- `workspace.current_dir` — the `cwd` for the cycle. Use the placeholder
  `@CWD@` and the driver substitutes the fixture directory.
- `transcript_path` — use `@TRANSCRIPT@` and the driver points it at the
  fixture's `transcript.jsonl`.
- `model.display_name` — any string (informational).
- `cost.total_cost_usd` — `0.0` for fixtures.

Minimum example:

```json
{
  "session_id": "fixture-session-NN",
  "workspace": {"current_dir": "@CWD@"},
  "model": {"display_name": "Sonnet 4.6"},
  "transcript_path": "@TRANSCRIPT@",
  "cost": {"total_cost_usd": 0.0}
}
```

### `transcript.jsonl`

A newline-delimited JSON snippet matching the Claude Code transcript format.
Each line is one of:

- `{"type": "user", "message": {"role": "user", "content": "..."}}`
- `{"message": {"content": [{"type": "tool_use", "name": "Read", "input": {...}}]}}`

Keep it small (50-100 lines max) — the cycle only reads the tail.

### `cwd-state.txt` (or `cwd-state/`)

A single file or a directory tree the planner can pick to read. Keep it
focused on the lens you're exercising — if the fixture is about an n+1 query,
the cwd-state should be the offending file.

If `cwd-state/` is a directory, the driver points `cwd` at it. If
`cwd-state.txt` is a single file, the driver points `cwd` at the fixture
directory and the file is picked by the planner directly.

### `notes.md`

Free-form. Describe:

- Which lens(es) should fire (ENGINEERING, SECURITY, etc.)
- What the ideal observation looks like (English summary)
- Any gotchas about replay (timing, ordering)

## Adding a new fixture

1. `mkdir test/eval/fixtures/session-NN`
2. Write the four files above. Use placeholders `@TRANSCRIPT@` / `@CWD@` in
   `input.json` for portability.
3. Hand-author the golden references under `test/eval/golden/session-NN/`
   (see `test/eval/golden/README.md`).
4. Verify the fixture replays: `bash test/eval/run-eval.sh --fixture session-NN --dry-run`.
   The dry run should produce a `<fixture>.observations.txt` file with one row
   per lens (the rows will be empty since LLM calls are skipped).
5. Without `--dry-run` (requires `OPENAI_API_KEY` in the shell), the rows will
   be populated. Compare against your golden refs and update either side as
   needed.
