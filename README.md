# Pair Polymath

> A pair-programming polymath for Claude Code — 7 specialist lens agents shadow your work and curate the field's best signals.

**Status:** v0.1.0-pre — work in progress, not yet installable. See `~/.claude/specs/2026-05-11-polymath-advisor-extraction-plan.md` for the roadmap.

## What's here so far

- `bin/statusline.sh` — the orchestrator (copied as-is from a working installation; refactored in M2+)
- `hooks/inject-monitor-insight.sh` — UserPromptSubmit hook that injects lens observations
- `hooks/cache-test-result.sh` — PostToolUse hook that captures test output for grounding

## Next milestones

- **M2-lean**: Extract config to `config/default.env` + `lib/`, add bats tests, shellcheck CI
- **M3**: Externalize lens metadata to `lenses/*.json`
- **M4**: Externalize prompts to `prompts/*.md`
- **M5-lean**: Minimal installer + `polymath status` CLI
- **M6-lean**: Single-page README

## License

MIT — see `LICENSE`.
