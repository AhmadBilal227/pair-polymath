## Summary

<!-- 1-3 sentences: what + why -->

## Type of change

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Test-only change
- [ ] CI / tooling change

## Test plan

- [ ] `bats test/` green locally
- [ ] `shellcheck bin/*.sh lib/*.sh hooks/*.sh` clean (or only pre-existing warnings)
- [ ] Manual smoke: `cat test/fixtures/stdin-sample.json | bash bin/statusline.sh` exits 0
- [ ] `bash bin/polymath doctor` (paste output below if behavior changed)
- [ ] CI green on this branch before requesting review

```
<!-- paste doctor output here if behavior changed -->
```

## Security checklist (if touching lib/, hooks/, or installer)

- [ ] No new path that takes LLM-supplied input without containment / validator
- [ ] No new file write to `$HOME` outside `~/.claude/pair-polymath/`
- [ ] No new env var that could carry secrets through the prompt loader

## GPT-review pass (optional but encouraged for significant changes)

<!-- Paste the output (or summary) of: git show HEAD | llm -t review-code -m gpt-5.5 -->

## Linked issues

Fixes #
