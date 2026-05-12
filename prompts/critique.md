You are reviewing ${PP_LENS_COUNT} advisor observations against grounded facts and explicit citation allowlists.

For EACH lens line, decide PASS or DROP based on these rules:

PASS criteria (ALL must hold):
- Citation check: see CITATION CHECK below.
- Concrete: the observation has a specific actionable next step.
- Grounded: the claim is supported by something visible in GROUNDED FACTS.
- Non-redundant: a different lens didn't already make the same observation from the same angle.

DROP if ANY hold:
- Citation fails: cites a path or symbol NOT in the allowlists (hallucinated). See CITATION CHECK for the matching rules.
- Vague: no actionable next step, or step is just "investigate" without specifics.
- Redundant: another lens already covered this angle.
- Stale: refers to an issue that the grounded facts show is already fixed.

CITATION CHECK: For any path the observation cites, BEFORE comparing,
normalize it: strip surrounding backticks, strip leading "./", strip
trailing ":<line-number>", strip trailing punctuation like "," ";" ")".
Then the normalized path is VALID if any of:
  (a) it appears exactly in VALID PATHS, OR
  (b) some VALID PATHS entry ends with "/" + the normalized path
      (i.e., the citation is the basename of a valid path), OR
  (c) the normalized path itself ends with "/" + some VALID PATHS entry.

For symbols, same normalize-then-check:
  Normalize: strip backticks, strip () suffix, strip ".method()" suffix
  to the leading identifier.
  VALID if the normalized symbol appears in VALID SYMBOLS exactly.

EXAMPLES OF VALID CITATIONS:
- Observation cites "handlers/users.ts:42" → strip ":42" → matches.
- Observation cites "`users.ts`" → strip backticks → matches via (b).
- Observation cites "calculateSum(a, b)" → strip "(a, b)" → matches.

EXAMPLES OF INVALID CITATIONS (DROP):
- Observation cites "lib/auth.ts" but allowlist has no path matching → DROP.
- Observation cites "validateRequest()" but VALID SYMBOLS has no such name → DROP.

EMPTY-ALLOWLIST EXCEPTION: If VALID PATHS is empty AND VALID SYMBOLS is
empty, the cycle has no extracted citations to check against (fresh repo,
cold start, or no file was read). In this case, SKIP the citation rule
entirely — judge observations on the other PASS criteria only (concrete,
grounded, non-redundant).

OUTPUT FORMAT — exactly one line per lens, in this shape:
lensN: PASS
lensN: DROP — short reason (mention which path/symbol failed if hallucinated)

No preamble. No markdown. ${PP_LENS_COUNT} lines total.
