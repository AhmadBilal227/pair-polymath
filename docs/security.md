# Security — User Guide

The repo-level [SECURITY.md](../SECURITY.md) covers the formal policy:

- **Reporting**: GitHub's private vulnerability reporting form
- **Supported versions**: current v0.5.x line
- **Threat model**: what leaves your machine, what doesn't

This doc is the operational companion — what you, the user, can verify yourself.

## Quick checks

```bash
# What did the last cycle WOULD send to the model? (P3.3 privacy log)
cat ~/.claude/cache/last-cycle-payload.json | jq .

# What did the last cycle actually produce?
polymath logs -n 1                              # most recent observation per lens

# What's my recent spend?
polymath cost --since 7d

# What's my cache dir? Verify it's not world-readable.
ls -ld ~/.claude/cache ~/.claude/pair-polymath 2>/dev/null

# Strict 'doctor' to confirm wiring
polymath doctor
```

The privacy log is a single overwriting JSON snapshot of the outgoing
payload — timestamp, session id, models, planner-picked file, byte counts,
and the first 500 chars of the transcript tail + grounded facts. Overwritten
each cycle (no history). `polymath status` also reports the path + age of the
most recent snapshot when one exists.

## What's hardened

See SECURITY.md's "Hardening highlights" section. Key points:
- Prompt loader: single-pass substitution prevents `${OPENAI_API_KEY}` exfiltration via critique-supplied drop reasons
- Containment: `pp_contain_path` rejects `.env`, `.ssh/*`, `*.key`, ~20 other patterns even inside cwd
- Budget: single shared atomic lock; reservation-before-spend; no split-lock races
- Installer: timestamped backup before any `settings.json` mutation; prompts on conflict; smoke-tests before activating

## What's NOT hardened (be aware)

- **Secrets you typed in your transcript.** The cycle reads the last 5 KB of your transcript. If you pasted an API key into chat, it's in scope. Use `polymath disable` for sensitive sessions.
- **Network observability.** All LLM calls go to OpenAI's API over HTTPS. Your network admin can see DNS queries to `api.openai.com`.

## File modes

```bash
# Created by the installer with mode 700 (owner-only):
ls -ld ~/.claude/pair-polymath           # always 700 — installer chmod's both fresh and existing
ls -ld ~/.claude/cache                   # 700 when installer created it fresh; existing dirs are NOT chmod'd

# If your cache predates the installer or was created by another tool, tighten manually:
chmod -R go-rwx ~/.claude/cache
```

The installer never chmod's a directory that already existed before it ran — to avoid clobbering permissions the user or another tool deliberately set. If you want strict 700 enforcement on every install run, file a feature request.
