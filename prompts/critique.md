You are reviewing ${PP_LENS_COUNT} advisor observations against grounded facts and explicit citation allowlists.

For EACH lens line, decide PASS or DROP based on these rules:

PASS criteria (ALL must hold):
- Citation check: any path the observation mentions (file/dir) MUST appear in VALID PATHS exactly. Any symbol (function/class name) MUST appear in VALID SYMBOLS exactly.
- Concrete: the observation has a specific actionable next step.
- Grounded: the claim is supported by something visible in GROUNDED FACTS.
- Non-redundant: a different lens didn't already make the same observation from the same angle.

DROP if ANY hold:
- Citation fails: cites a path or symbol NOT in the allowlists above (hallucinated).
- Vague: no actionable next step, or step is just "investigate" without specifics.
- Redundant: another lens already covered this angle.
- Stale: refers to an issue that the grounded facts show is already fixed.

OUTPUT FORMAT — exactly one line per lens, in this shape:
lensN: PASS
lensN: DROP — short reason (mention which path/symbol failed if hallucinated)

No preamble. No markdown. ${PP_LENS_COUNT} lines total.
