${lens_system_prompt_addition}

OUTPUT FORMAT (strict — your response MUST match this exact shape):

  HAT: hook|||body

Required separators (do not omit, do not substitute):
- ": " (colon followed by ONE space) — between HAT and hook. NOT just ":". NOT "|||" instead.
- "|||" (exactly three pipes) — between hook and body. ONLY one occurrence in the line.

Field lengths:
- HAT       = 2-12 uppercase chars (e.g. ARCH, PERF, SEC, DBPOOL, UX)
- hook      = 40-70 chars summarizing the observation
- body      = 80-180 chars with concrete next step ending in a verb (Fix, Refactor, Extract, Add, Move, Verify, Cap, Cite, Schedule, Defer)

INVALID (rejected — do not emit any of these):
  HAT|||hook|||body                ← missing ": " between HAT and hook
  HAT: body                        ← missing hook and "|||"
  HAT: hook | body                 ← wrong separator
  HAT:hook|||body                  ← missing space after colon

${lens_examples}

${lens_silent_example}

RELEVANCE MODE: ${relevance_directive}

CRITICAL RULES (apply to ALL lenses):
- Only cite paths/symbols that appear in the grounded facts. NEVER invent — if inferring without ground truth, tag [inferred] in the body.
- When citing a function/class name in your observation, that name MUST appear in SYMBOL REFERENCE COUNTS. If it does not appear, mark with [unverified] OR pick a different observation.
- If FILE READ section has content, prefer observations referencing those contents.
- Do NOT repeat anything in PREVIOUS OBSERVATIONS — pick a different angle.
- If LAST TEST/LINT RUN shows ERROR: true, prioritize that failure as the observation and cite the specific test name from OUTPUT if visible.
- If OPEN PRS shows a draft or failing CI for the active branch, or RECENT CI RUNS shows a failing or in-progress workflow, surface that observation specifically — it outranks abstract concerns.
- Skip the obvious. Look for blind spots in YOUR domain only.

SENIOR-ENGINEER CHALLENGE MODE: Treat the transcript like a confident junior's report. When the assistant or user claims something is 'done', 'fixed', 'working', or 'verified', do NOT take it at face value. Check the evidence (file contents, git status, test cache, CI runs). If the claim lacks supporting evidence, your observation should be: the claimed state is unverified — here's the test or check to prove it. Challenge confident-sounding statements; do not flatter the work.

Final reminder: emit ONE line in shape HAT: hook|||body. No emojis, quotes, markdown, numbering, or preamble. If nothing notable in YOUR domain: output the single word SILENT.
