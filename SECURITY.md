# Security Policy

## Supported Versions

| Version       | Supported          |
| ------------- | ------------------ |
| v0.5.x        | :white_check_mark: |
| < v0.5.0      | :x:                |

## Reporting a Vulnerability

**Preferred channel:** GitHub's private vulnerability reporting at
<https://github.com/AhmadBilal227/pair-polymath/security/advisories/new>.
This creates a private advisory visible only to the maintainer; no public
issue is created.

**Fallback channel:** if the GitHub form is unavailable to you (e.g. you're
reporting anonymously or via a third party), email the address listed on
[`@AhmadBilal227`'s GitHub profile](https://github.com/AhmadBilal227).

Do NOT open a public issue for security concerns until coordinated
disclosure has happened.

**Response timeline:**
- Acknowledgement: within 7 days
- HIGH severity fix or mitigation: target 30 days
- MEDIUM severity: target 90 days

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
- Secret-file denylist: `pp_contain_path` rejects three independent classes (case-insensitive, so macOS APFS `.ENV` doesn't bypass): (1) basename matches against ~30 patterns (`.env`, `*.pem`, `*.key`, `*credentials*`, `*secrets*`, `id_rsa*`, `*_rsa`, `service-account*.json`, `*.kubeconfig`, `wp-config.php`, `.git-credentials`, `.aws_credentials`, `.pgpass`, `*.private_key`, and similar); (2) any path component matching a secret-directory glob (`secrets`, `private`, `.ssh`, `.aws`, `.credentials`, `.keys`, `.secrets`) — so `secrets/config.json` is rejected even with an innocuous basename; (3) the cwd itself: if the BASE directory's deepest component matches a secret-dir pattern (e.g. `cd ~/.ssh && polymath ...`), every file inside it is rejected — closes the gap where a shallow `cand_rel` had nothing for the dir-walk to find. Symlinks are checked on BOTH sides (link basename AND resolved real path) to prevent basename-trust bypass. Pathname-expansion of patterns is suppressed (`set -f` discipline, with the caller's noglob state preserved on exit so it cannot silently disable). User-supplied glob patterns are lowercased before match, so `PP_SECRET_FILE_PATTERNS_EXTRA="*.PEM"` matches `server.pem`. Absolute paths get basename-only matching (the dir-component walk only runs on relative paths) so macOS `/private/var` system paths cannot false-positive. Full source-of-truth pattern list lives in [`lib/grounding.sh`](lib/grounding.sh). Configurable via `PP_SECRET_FILE_PATTERNS_EXTRA` / `PP_SECRET_DIR_PATTERNS_EXTRA` (additive) or `PP_SECRET_FILE_PATTERNS` / `PP_SECRET_DIR_PATTERNS` (replace; explicit `""` disables that check AND ignores the matching `_EXTRA` — a true "off" switch; whitespace-only logs a warning and reverts to defaults).
- Cache files: id-keyed, not numeric-index-keyed (reordering / disabling lenses cannot serve stale observations under a wrong identity).
- Installer: prompts before replacing an existing statusLine (won't silently clobber ccusage / other tools); merges `settings.json` atomically with timestamped backup; smoke-tests `statusline.sh` before activating.
- Uninstaller: matches by basename so an install from a moved checkout still cleans up; preserves third-party hooks.

## v0.5.1 retry router shadow log + KPI log

When `PP_RETRY_ROUTER_SHADOW=1` (or `PP_RETRY_ROUTER_ENABLE=1`), pair-polymath writes per-cycle telemetry to two append-only JSONL files in `PP_CACHE_DIR` (default `$CLAUDE_DIR/cache`, with `CLAUDE_DIR=~/.claude` unless overridden; mode 0600, in the 0700 cache dir):

- `retry-router-shadow.jsonl` — one record per critique DROP. Fields: timestamp, session id, lens id, **drop-reason class** (one of `citation_fail | stale | vague | redundant | format | unknown`), confidence class (`high|low`), the model the router *would* pick, and the canary-active flag. It records the drop-reason **class only** — the raw drop-reason text is never written, so there is no raw critique text and no secret-bearing content to redact.
- `kpi-cycle.jsonl` — one rollup record per cycle. Fields: timestamp, session id, cost/retry USD estimates, call counts, picked-lens count, phase + phase source, retry acceptance rate, drop count, cycle outcome, SLO-breach flag. All values are derived counts and USD estimates — no transcript content, no file content, no drop text.

Because neither log writes raw drop text or transcript content, no body redactor is invoked. Both logs rotate at `PP_LOG_MAX_BYTES` (10 MB default) to a single `.1` retention slot, under an `mkdir`-lock so parallel lens fan-out can't tear a line. To inspect: `polymath retry-router shadow-summary` / `polymath kpi`. To clear: remove `retry-router-shadow.jsonl` and `kpi-cycle.jsonl` from `PP_CACHE_DIR`.

## Known limitations

- The `--network` doctor probe requires a real OpenAI key. It costs ~$0.0001 per invocation.
- Bash 3.2 (macOS default) is the floor; older versions are rejected by `polymath doctor`.
- WSL is untested.

Issues + PRs welcome.
