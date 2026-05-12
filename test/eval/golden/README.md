# Golden references

For each fixture `test/eval/fixtures/session-NN/`, the matching golden refs
live at `test/eval/golden/session-NN/<LENS_ID>.txt`. One file per lens that
should produce a defensible observation for that fixture.

Lens IDs come from `lenses/*.json`. The default set is:

- `UX_DESIGN`
- `ENGINEERING`
- `SECURITY`
- `PERF_FINOPS`
- `PRODUCT_BIZ`
- `STRATEGIC_FOUNDER`
- `COGNITIVE_FLOW`

You don't have to provide a golden for every lens — only the ones you expect
to fire meaningfully on this fixture. Missing goldens are flagged as
`unscored` in the score report (not penalized).

## Schema

One line per file, format:

```
TOPIC|||hook one-liner|||body 100-200 chars
```

`TOPIC` is the HAT (e.g. `ARCH`, `SEC`, `OPS`) the analyst would prefix.
`hook` is the 40-70 char attention-grabbing fragment.
`body` is the 80-180 char concrete observation with a next-step verb.

## Example

`test/eval/golden/session-01/ENGINEERING.txt`:

```
ARCH|||Inner findOne loop runs N+1 queries on users.posts|||Each user iteration triggers a fresh DB roundtrip in handlers/users.ts. Refactor to a single join or batched Prisma include. Verify with EXPLAIN ANALYZE.
```

## Curating goldens

- Hand-write them — they're the ground truth the scorer compares against.
- One angle per lens. If two angles are equally good, pick the one a senior
  engineer would mention first.
- Cite specific files/symbols from the fixture's `cwd-state.txt` so the
  scorer can tell hallucinated cites apart from valid ones.
- Keep the same `TOPIC|||hook|||body` shape an analyst would emit. The scorer
  doesn't enforce shape on goldens, but a similar shape gives the LLM scorer
  a cleaner comparison.

## Updating goldens

Goldens are intentionally hand-curated. Do NOT script-generate them from LLM
output (that would defeat the purpose of measuring against a held-out
reference). If a fixture's scenario changes, update both the fixture AND
the golden in the same commit.
