# Demo recipe

The README's "What you'll see" section currently uses a text mockup. A real asciinema cast is more compelling for first-time visitors. Run this when you want to (re)record it.

## Prereqs

```bash
brew install asciinema   # macOS
# or
pip install --user asciinema
```

## Recording

1. Open a clean terminal window (no scrollback noise). Set a reasonable width: `resize -s 30 110` or your terminal's preferred size.
2. Make sure `polymath doctor` is green and the cycle has produced at least one fresh observation. If your cache is stale, force a cycle by submitting a Claude Code prompt and waiting ~5 min.
3. Record:

   ```bash
   asciinema rec docs/demo.cast \
     --title "Pair Polymath v0.1.0-alpha" \
     --idle-time-limit 2
   ```

4. The recording session: run these commands in order, ~3s pause between each:

   ```bash
   bash bin/polymath status
   bash bin/polymath doctor
   bash bin/polymath logs -n 3
   bash bin/polymath cost     # requires v0.2 — currently in PR #10. Omit if not yet merged.
   ```

   If `polymath cost` isn't on your branch yet, drop that line and stick to `status` / `doctor` / `logs`.

5. Exit with `Ctrl-D`.

6. Test playback: `asciinema play docs/demo.cast`.

7. (Optional) Render to GIF for embedding in markdown:

   ```bash
   # Requires agg: cargo install --git https://github.com/asciinema/agg
   agg --theme monokai docs/demo.cast docs/demo.gif
   ```

8. Commit. Embed in README:

   ```markdown
   ![Pair Polymath demo](docs/demo.gif)
   ```

## Why a recipe, not a recording

The cast file would need to be re-recorded every time `polymath status` output format changes. Easier to keep this recipe + let the maintainer re-record at release time.
