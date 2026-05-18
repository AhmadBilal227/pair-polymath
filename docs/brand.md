# Pair Polymath Brand Book

The brand identity for pair-polymath is *quiet presence*. Many specialists watching alongside the user — never interrupting, never shouting. This document codifies the marks, palette, and voice so future contributions stay coherent.

---

## The two marks

### `⚛` — the polymath sigil

**Glyph:** U+269B (ATOM SYMBOL).
**Semantic:** electrons orbiting a nucleus — many specialists orbiting one work.
**Render:** single cell, broad font support across macOS Menlo, Linux DejaVu, Powerline-patched fonts. Falls back to `*` on POSIX/non-UTF-8 locales (see `lib/brand.sh:_pp_brand_sigil`).

**When to use:**
- Prefix on advisor observations on statusline line 2 (color-coded by lens that spoke)
- Header of `polymath status`, `polymath doctor` output (color cycles by wall-clock)
- Header of the `[BACKGROUND ADVISORY]` block injected into Claude's context
- In the `polymath` CLI banner / first-touch surface

**When NOT to use:**
- On user-authored output (e.g., user's own scripts)
- More than once per line (sigil is a signature, not punctuation)
- Without color when the context is "polymath is the source" (color carries the lens identity)

### `⠁ ⠂ ⠄ ⡀` — the constellation (loading)

**Glyphs:** U+2801, U+2802, U+2804, U+2808 (BRAILLE PATTERN DOTS-1..4).
**Semantic:** single dots moving through positions — many minds quietly attending.
**Render:** 4-frame cycle, 1 second per frame, wall-clock-driven (no inter-process state needed).

**When to use:**
- Cycle-in-flight: statusline line 2 fallback when a polymath cycle is running but hasn't produced output yet
- Install: between `apt-get install` / `pip3 install --user` steps in `bin/install.sh`
- Onboard wizard: between steps in `polymath onboard`
- Update: during `polymath update` git pull

**When NOT to use:**
- As a standalone identity (it's a loading mark, not a sigil)
- More than once per line
- For errors (use `◌` paused / `⚠` warning instead)
- At sub-1s frame rate (faster than 1s reads as anxiety, not presence)

---

## The palette

Six distinct hues, one default. Locked in `lib/brand.sh:_pp_brand_lens_hue`.

| Lens | Hue | ANSI 256 | Voice |
|---|---|---|---|
| UX_DESIGN | SOFT_PURPLE | `38;5;139m` | reflective, considered |
| ENGINEERING | SOFT_AMBER | `38;5;179m` | warm, durable |
| SECURITY | SOFT_CRIMSON | `38;5;167m` | alert, alive |
| PERF_FINOPS | SOFT_GREEN | `38;5;108m` | grounded, calm |
| PRODUCT_BIZ | CYAN_SOFT | `38;5;117m` | forward-looking |
| STRATEGIC_FOUNDER | SOFT_BLUE | `38;5;110m` | reflective (a11y: distinct from UX) |
| COGNITIVE_FLOW | DIM_GRAY | `38;5;243m` | quiet, observational |
| (default / idle) | SOFT_PURPLE | `38;5;139m` | polymath identity color |

**Accessibility notes:**
- STRATEGIC_FOUNDER and UX_DESIGN are *deliberately* distinct hues (139 vs 110). Earlier drafts shared SOFT_PURPLE for both; ui-designer review flagged deuteranopia confusion. **Do not collapse this back.**
- All hues from the muted/desaturated end of the 256-color cube — none are pure RGB primaries. Reads softer on f.lux/night-shift displays.
- Always emit a `\033[0m` reset after a colored sigil so adjacent text is unaffected.

---

## Voice

**Lead words:**
- *Pair* — there are two of you (Claude + polymath), three counting the user
- *Polymath* — many minds, one voice
- *Untrusted advisory* — subordinate to Claude's judgment, never authoritative
- *Watching* — presence is the value, not interruption
- *Whispers* — never shouts

**Do:**
- Say "paused — LLM cycle disabled" not "DISABLED!!!" or "❌ POLYMATH OFF"
- Say "no fresh insight in last 15m" not "WAITING FOR DATA"
- Say "polymath enable to resume" not "click here to restart" (terminal-first; clarity over hype)
- Use precise count ("23 advisories today") not vague ("lots of insights")
- Always qualify a glyph with text on its first surface (e.g., `⚛ paused — LLM cycle disabled`); after the first surface, the glyph stands alone

**Don't:**
- Use exclamation points
- Use emoji except as already-established (🪄 line 1, ✨ fresh, ⚠ alert, ◌ paused, ▸ tip)
- Introduce new glyphs without updating this brand book first
- Animate glyphs that already have meaning (◌ stays still; ⚛ stays still; only color cycles)
- Use the brand sigil for non-polymath output

---

## Layout policy

**2 lines canonical.** Line 1 = status (branch, context, cost). Line 2 = advisor/teacher rotation.

**1 line when paused.** Line 2 collapses to `◌ ⚛ paused — LLM cycle disabled (polymath enable to resume)`. No advisor rotation while paused.

**No 3rd or 4th line.** Statusline is ambient, not a dashboard. (`polymath status` is the dashboard.)

---

## Reference implementations

- `lib/brand.sh` — sigil + constellation + palette helpers (canonical implementation)
- `test/brand.bats` — pinned behavior for sigil fallback, hue palette, frame cycling, statusline integration

---

## When the brand changes

Update this file FIRST. Then `lib/brand.sh`. Then call sites. Then `test/brand.bats`. Brand drift is a real failure mode in long-running shell projects (different glyphs creeping in across PRs); the doc-first discipline is the guardrail.
