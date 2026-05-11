# Security Policy

## Supported Versions

| Version       | Supported          |
| ------------- | ------------------ |
| v0.1.x-alpha  | :white_check_mark: |
| < v0.1.0      | :x:                |

## Reporting a Vulnerability

Please report security vulnerabilities by emailing the maintainer at the address on the GitHub profile of `@AhmadBilal227`. Do NOT open a public issue for security concerns until coordinated disclosure has happened.

You should receive an acknowledgement within 7 days. Expect a fix or mitigation within 30 days for HIGH-severity issues, 90 days for MEDIUM.

## Threat Model Summary

Pair Polymath runs in the user's terminal with their UID. It does NOT run as root, does NOT bind a network listener, and does NOT install background daemons.

What leaves the user's machine per cycle:
- The last ~5 KB of their Claude Code transcript
- `git status` + last 5 commit subjects of the current working directory
- The first ~3 KB of ONE file, picked by an LLM planner and containment-checked against the working dir via `realpath` prefix match
- Hacker News top-stories and recent arXiv `cs.AI` / `cs.HC` titles (public RSS, no PII)

What never leaves:
- Environment variables. The prompt loader is **single-pass** over placeholders found in the *original* template only — a critique-LLM-supplied value containing `${OPENAI_API_KEY}` cannot be re-scanned and expanded into the rendered prompt. Regression-tested in `test/prompt-loader.bats`.
- Full conversation history (only the tail).
- Files outside the user's working directory (`pp_contain_path` enforces realpath prefix match).

## Hardening highlights (relative to prior bare-install version)

- Budget tracking: single shared `mkdir`-based lock; no split-lock races between `inc` and `reserve` writers.
- Cycle gate: atomic `mkdir LOCK`, not check-then-touch.
- `session_id`: sanitized via `tr -cd 'a-zA-Z0-9._-' | cut -c1-64` before any path use.
- Lens count: hard-capped at `PP_LENS_MAX=16` (DoS guard against a stuffed user-override dir).
- Grep validator: rejects leading `-` (option injection), requires ≥3 alphanumeric chars (rejects pattern-of-metachars decoys).
- Cache files: id-keyed, not numeric-index-keyed (reordering / disabling lenses cannot serve stale observations under a wrong identity).
- Installer: prompts before replacing an existing statusLine (won't silently clobber ccusage / other tools); merges `settings.json` atomically with timestamped backup; smoke-tests `statusline.sh` before activating.
- Uninstaller: matches by basename so an install from a moved checkout still cleans up; preserves third-party hooks.

## Known limitations

- The `--network` doctor probe requires a real OpenAI key. It costs ~$0.0001 per invocation.
- Bash 3.2 (macOS default) is the floor; older versions are rejected by `polymath doctor`.
- WSL is untested.

Issues + PRs welcome.
