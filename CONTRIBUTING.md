# Contributing to Pair Polymath

Thanks for considering a contribution. This is an alpha project with rapid iteration — expect APIs to shift.

## Dev setup

```bash
git clone https://github.com/AhmadBilal227/pair-polymath
cd pair-polymath
brew install bats-core shellcheck jq    # macOS
# OR
sudo apt-get install -y bats shellcheck jq    # Ubuntu

bats test/                              # run the test suite
shellcheck bin/*.sh lib/*.sh hooks/*.sh # lint
bash bin/polymath doctor                # see your machine's state
```

## How to propose a change

1. Open an issue first if the change is non-trivial (>50 lines) — alignment first, code second.
2. Fork + branch from `main`. Branch names: `feat/<short-name>`, `fix/<short-name>`, `docs/<short-name>`.
3. Make focused commits. One logical change per commit.
4. **Run the full test suite + shellcheck** before opening a PR. CI does this automatically but the loop is faster locally.
5. **Run `polymath doctor`** on your local install (or a clean Docker container) and paste the output in the PR description.
6. Open the PR against `main`. Fill the PR template completely.
7. CI must be green before merge: `bats`, `shellcheck`, `install-test`. No exceptions.
8. After merge, your branch will be auto-deleted (GitHub setting).

## Commit conventions

We use lowercase, imperative present-tense subjects, with optional scope:

```
ci: tighten workflow triggers + permissions
fix(loader): handle stray } before placeholder
docs: add SECURITY.md
test(budget): pre-create file in setup
```

Body lines wrap at ~72 chars. Reference issues with `Refs #N` or `Fixes #N`.

## Code style

- Bash 3.2 portable. No `mapfile`, no `${var,,}`, no `local -n`. Use `while IFS= read -r` for line iteration.
- All shared state uses atomic `mkdir`-based locking. No `flock` (not portable).
- All LLM-influenced paths go through `lib/grounding.sh` (`pp_contain_path`, `pp_safe_grep_pattern`).
- All user-overridable behavior reads from `config/default.env` (built-in) and `~/.claude/pair-polymath/config/user.env` (user override).
- Functions that need to look up variables in the caller's scope use `_pp_`-prefixed locals to avoid shadowing.

## Testing

- Every behavioral change needs at least one bats test.
- Security-relevant fixes need a regression test that fails BEFORE the fix and passes AFTER. Example: `test/prompt-loader.bats` "substitution values are NOT re-scanned (secret-leak guard)".
- Tests use `HOME=$(mktemp -d)` and `CLAUDE_DIR=$HOME/.claude` to stay hermetic — they never touch the developer's real `~/.claude/`.

## GPT-review pattern

Significant changes get an external LLM code review before merge:

```bash
git show <SHA> | llm -t review-code -m gpt-5
# or whatever frontier model your llm CLI has access to:
git show <SHA> | llm -t review-code         # uses your llm default
```

The maintainer uses `gpt-5.5` (where available) for higher-severity findings; `gpt-5` and `gpt-4o` produce comparable signal for most refactors. This is a documented norm, not a CI gate. PR reviewers SHOULD do this for any change touching `lib/`, `bin/`, hooks, or workflow files.

The `llm` CLI is by Simon Willison (`pip3 install --user llm`). See `llm models` for what your install has.

## Reporting bugs

Use the issue templates at `.github/ISSUE_TEMPLATE/`. The bug template prefers `polymath doctor` output, but has a separate "Bootstrap failure" path for cases where `polymath` itself won't run (install / bash version / missing-dep bugs).

## Releasing (maintainers only)

1. Bump `VERSION` to the new SemVer.
2. Update `CHANGELOG.md` — move `[Unreleased]` entries under `## [vX.Y.Z] — YYYY-MM-DD`.
3. Commit + PR + merge to `main`.
4. After CI green: `git tag -a vX.Y.Z -m "..."` and `git push origin vX.Y.Z`.
5. The release workflow (when it lands in Sprint C) auto-creates the GitHub Release. Until then, run `gh release create vX.Y.Z --notes "..."` manually.

## License

MIT — your contributions are licensed under the same terms.
