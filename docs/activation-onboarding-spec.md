# Activation Onboarding + Display-Only Fun Mode

Status: implementation spec for the activation release.

## Goal

Pair Polymath should install safely, then help a new user choose how the system behaves before the first real session. This release adds a terminal onboarding wizard, a small five-lens foothold from the expanded taxonomy, active-lens presets, and display-only fun mode.

This is not the dynamic agent-workforce release. Agent add/adjust/promote/fire remains gated on OAR quality and the v0.5.3 workforce spec.

## Onboarding Flow

`polymath onboard [--from-install] [--yes]` runs a Bash 3.2-compatible terminal wizard:

1. Welcome and current install summary.
2. Role selection: `solo-founder`, `senior-engineer`, `product-builder`, `security-ops`, `custom`.
3. Project phase: `fresh`, `scaling`, `mature`.
4. Lens preset: `balanced`, `solo-founder`, `dev-team`, `product-launch`, `security-hardened`, `deep-review`.
5. Optional deterministic custom lens creation.
6. Cost profile: `conservative`, `balanced`, `deep`.
7. Display-only fun mode: off by default, opt-in styles.
8. Preview config and active lens IDs before writing.
9. Apply to `$PP_USER_CONFIG` and `$PP_STATE_DIR/config/lenses-enabled.txt`, then run doctor unless skipped.

Installer handoff happens only after the statusline smoke test and successful `settings.json` merge. `--dry-run` never invokes onboarding. Non-interactive install prints the later command instead of prompting.

## Lens Foothold

The release adds five built-in lenses, but keeps the legacy seven active by default unless onboarding writes an active-lens selection file:

- `CFO`
- `PRE_MORTEM`
- `DEVILS_ADVOCATE`
- `HISTORIAN`
- `DATABASE_ENGINEER`

The active set is stored in `$PP_STATE_DIR/config/lenses-enabled.txt`, one lens ID per line. If the file is absent, the loader preserves the legacy seven-lens default plus user-created lenses. If present, the loader keeps only listed IDs after normal built-in/user override resolution.

## Fun Mode

Fun mode is presentation only. It can render short statusline/CLI messages from derived local signals, but it must not alter analyst prompts, advisory injection, router choices, or OAR labels.

Config keys:

```bash
PP_FUN_MODE=0
PP_FUN_STYLE=mentor
PP_FUN_INTENSITY=1
PP_FUN_ALLOW_ROAST=0
PP_FUN_COOLDOWN_S=300
PP_FUN_MAX_CHARS=120
```

Allowed styles: `gentle`, `hype`, `dry`, `mentor`, `founder`, `roast`. Roast requires explicit opt-in and targets workflow/process only.

Safe signals: git dirty/staged state, last test status, idle age, context pressure, budget pressure, router phase, and derived tool/edit patterns. Do not use raw transcript text, raw test output, memory bodies, advisor bodies, or privacy-log previews for fun output.
