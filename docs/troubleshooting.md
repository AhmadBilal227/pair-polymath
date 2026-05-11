# Troubleshooting

Start with `bash bin/polymath doctor`. It runs 12 checks and prints a summary. Below: what each result means and how to resolve.

## `✗ bash version too old`

Pair Polymath requires bash ≥3.2. macOS ships 3.2; Linux usually has ≥5. If you're on a stripped image (BusyBox, sh-only Alpine), install bash:

```bash
# Ubuntu / Debian
sudo apt-get install -y bash
# Alpine (BusyBox)
apk add bash
```

## `✗ jq not installed`

`brew install jq` (macOS) or `sudo apt-get install -y jq` (Linux). The installer prompts for this; if you skipped, run it manually.

## `✗ llm not on PATH`

The `llm` CLI was installed via `pip3 install --user` but `~/.local/bin` isn't on your PATH. Add this to your shell rc:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

…and restart your shell.

## `✗ openai key not set`

```bash
llm keys set openai
# (paste your sk-... key)
```

Get one from [platform.openai.com/api-keys](https://platform.openai.com/api-keys).

## `✗ settings.json invalid` / `not found`

Run `./bin/install.sh` from this checkout. The installer atomically merges in the statusLine + 2 hooks with a timestamped backup of any existing file.

## `⚠ statusLine wired — points to a different script`

You have a statusLine pointing at another tool (ccusage, etc.). The installer asked before replacing and you said no. To switch later: re-run `./bin/install.sh` and answer Y.

## `✗ hooks wired — missing or pointing elsewhere`

The `UserPromptSubmit` hook (`inject-monitor-insight.sh`) and/or `PostToolUse` hook (`cache-test-result.sh`) aren't installed. Re-run `./bin/install.sh`.

## `✗ lenses — registry empty`

`$PP_ROOT/lenses/` doesn't exist or has no parseable JSON. If you're running from a fresh `git clone`, this shouldn't happen — verify the clone is complete: `ls $PP_ROOT/lenses/`.

## `✗ prompts — missing X Y Z`

Same as lenses but for `$PP_ROOT/prompts/`. Re-clone or check for accidental deletions.

## `✗ statusline smoke — failed on sample stdin`

The pre-install smoke test failed. Run it manually for the error:

```bash
cat test/fixtures/stdin-sample.json | bash bin/statusline.sh
echo "exit: $?"
```

## `⚠ budget tracker — no entry yet today`

Normal at start of day. The first lens cycle will create `~/.claude/cache/pp-budget-YYYYMMDD.txt`.

## "I see line 1 but no line 2 ever"

- Run `polymath status` — is `External LLM: 1`? If 0, you've disabled it (`polymath enable` to re-enable).
- Wait 5 minutes. The cycle interval is `PP_PARALLEL_INTERVAL_S=300`.
- Check `polymath logs` — observations may exist but the rotating-slot timing might not have hit.
- Check `polymath cost` — if it shows recent cycles, the LLM path is working but observations may be empty (network blip, key failure mid-cycle).

## "polymath update --yes hung in CI"

Known: `--yes` skips the installer re-run by design (install.sh has interactive prompts). After pull, if `bin/install.sh` was touched, re-run it manually. See `polymath update --help`.

## "Custom lens isn't being picked up"

- `polymath status` lens count should be 8 (built-in 7 + your 1).
- File must be valid JSON: `jq empty ~/.claude/pair-polymath/lenses/your-lens.json`.
- `id` field must be unique; matching a built-in id makes your file REPLACE the built-in (intentional override).
- Hard cap `PP_LENS_MAX=16` — beyond that, extras are silently dropped.

If still stuck, open an issue with `polymath doctor` output attached.
