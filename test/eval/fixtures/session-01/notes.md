# session-01 — n+1 query in listUsersWithPosts

## Scenario

User asks Claude Code to investigate a slow `/api/users` endpoint. The
relevant file (`cwd-state.txt`, treated as `handlers/users.ts` content)
contains a classic n+1 query: `prisma.post.findMany` is called inside a
`for (const user of users)` loop.

The user's most recent message asks for verification (typecheck) before
treating the patch as "done" — a senior-engineer challenge moment.

## Lenses that should fire

- **ENGINEERING (primary)** — name the n+1, cite the file + offending
  loop, propose the Prisma `include` or single JOIN refactor as next step.
- **PERF_FINOPS (secondary)** — same data, but framed as response-time + DB
  cost: 51 queries per request blows out the per-request DB budget.
- **COGNITIVE_FLOW (tertiary)** — the user explicitly asked for verification
  before claiming done; surface the "claim made without typecheck evidence"
  observation.
- **SECURITY / UX_DESIGN / PRODUCT_BIZ / STRATEGIC_FOUNDER** — should mostly
  SILENT or produce low-confidence observations. The golden refs only
  populate the three lenses above; the others are intentionally missing so
  the scorer doesn't penalize the model for silence on irrelevant lenses.

## Gotchas for replay

- The transcript ends with the user requesting a typecheck — so the model
  should NOT credulously accept the "Done — patch applied" claim. Goldens
  reflect that challenge.
- `cwd-state.txt` is a single file (not a directory). The driver points
  `cwd` at the fixture directory so the planner can list/read it. The
  filename is intentionally `cwd-state.txt` (not `users.ts`) — the analyst's
  prompt should still surface the n+1 if the model is paying attention to
  the transcript context.
