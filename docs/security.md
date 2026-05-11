# Security — User Guide

The repo-level [SECURITY.md](../SECURITY.md) covers the formal policy:

- **Reporting**: GitHub's private vulnerability reporting form
- **Supported versions**: v0.1.x-alpha and later
- **Threat model**: what leaves your machine, what doesn't

This doc is the operational companion — what you, the user, can verify yourself.

## Quick checks

```bash
# Show what would be sent in the next cycle (overwritten each cycle, not archived)
cat ~/.claude/pair-polymath/cache/last-cycle-payload.json | jq .

# Show what file the planner picked last (and was containment-checked)
polymath logs --lens ENGINEERING -n 1 | head -3
```

(The privacy log lands in P3.3; until then, the `last-cycle-payload.json` file may not exist yet.)

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
ls -la ~/.claude/pair-polymath/
# Expected: drwx------ (mode 700)
```

If the dir is group/world-readable, tighten:

```bash
chmod -R go-rwx ~/.claude/pair-polymath/
```
