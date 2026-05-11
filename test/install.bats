#!/usr/bin/env bats
# Installer tests — P2.3 flags, audit log, bare-install detection.
# Every test uses a hermetic HOME (mktemp -d) and never touches the dev's
# real ~/.claude/.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$HOME/.claude"

  # Some CI environments (the standalone bats workflow) install jq but NOT
  # llm. The installer's check_or_install would then attempt a real
  # `pip3 install --user llm` which is slow + flaky. We shim llm with a
  # no-op so the dep-check passes immediately and tests stay hermetic.
  if ! command -v llm >/dev/null 2>&1; then
    PP_TEST_SHIM_DIR="$HOME/_shimbin"
    mkdir -p "$PP_TEST_SHIM_DIR"
    cat > "$PP_TEST_SHIM_DIR/llm" <<'LLM'
#!/usr/bin/env bash
# Test shim for llm — accepts any subcommand, succeeds, emits no keys.
case "${1:-}" in
  keys) [ "${2:-}" = "list" ] && exit 0 ;;
esac
exit 0
LLM
    chmod +x "$PP_TEST_SHIM_DIR/llm"
    export PATH="$PP_TEST_SHIM_DIR:$PATH"
  fi
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

# Normalize installer output: strip absolute paths, timestamps, hostnames
# so golden snapshots stay stable across machines.
_pp_normalize_install_output() {
  local input="$1"
  printf '%s' "$input" \
    | sed -E 's@'"$PP_ROOT"'@<PP_ROOT>@g' \
    | sed -E 's@'"$HOME"'@<HOME>@g' \
    | sed -E 's@/var/folders/[A-Za-z0-9._/-]+@<TMP>@g' \
    | sed -E 's@/tmp/[A-Za-z0-9._-]+@<TMP>@g' \
    | sed -E 's@[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z@<TS>@g' \
    | sed -E 's@\.bak\.[0-9]+@.bak.<TS>@g' \
    | sed -E 's@v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+)?@<VERSION>@g' \
    | sed -E 's@(jq: )[^ ]+@\1<PATH>@g' \
    | sed -E 's@(llm: )[^ ]+@\1<PATH>@g'
}

# ============================================================
# Flag parsing
# ============================================================

@test "install --help: exits 0 and lists all flag names" {
  run bash "$PP_ROOT/bin/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"--no-sudo"* ]]
  [[ "$output" == *"--non-interactive"* ]]
  [[ "$output" == *"--help"* ]]
  [[ "$output" == *"Exit codes:"* ]]
}

@test "install -h: alias works" {
  run bash "$PP_ROOT/bin/install.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
}

@test "install: unknown flag exits 2 with stderr message" {
  run bash "$PP_ROOT/bin/install.sh" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
  [[ "$output" == *"--help"* ]]
}

@test "install --help matches golden snapshot (byte-exact)" {
  run bash "$PP_ROOT/bin/install.sh" --help
  [ "$status" -eq 0 ]
  golden="$PP_ROOT/test/fixtures/install-help.golden.txt"
  if [ ! -f "$golden" ]; then
    skip "golden fixture missing: $golden"
  fi
  diff <(printf '%s\n' "$output") "$golden" || {
    echo "Help text drift — to update fixture:"
    echo "  bash $PP_ROOT/bin/install.sh --help > $golden"
    return 1
  }
}

# ============================================================
# --dry-run
# ============================================================

@test "install --dry-run: zero filesystem changes" {
  before=$(find "$HOME" -mindepth 1 2>/dev/null | sort)
  run bash "$PP_ROOT/bin/install.sh" --dry-run --yes
  [ "$status" -eq 0 ]
  after=$(find "$HOME" -mindepth 1 2>/dev/null | sort)
  [ "$before" = "$after" ] || {
    echo "FS changed:"
    diff <(echo "$before") <(echo "$after")
    return 1
  }
}

@test "install --dry-run: stdout contains [DRY-RUN] markers" {
  run bash "$PP_ROOT/bin/install.sh" --dry-run --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [[ "$output" == *"dry-run complete"* ]]
}

@test "install --dry-run: completes successfully (exit 0)" {
  run bash "$PP_ROOT/bin/install.sh" --dry-run --yes
  [ "$status" -eq 0 ]
}

# ============================================================
# --yes / -y
# ============================================================

@test "install --yes: completes without reading stdin" {
  # stdin is closed via </dev/null. If --yes didn't skip reads, the prompts
  # would either block (which bats would time out on) or get empty strings
  # and possibly fail.
  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  # Settings file created.
  [ -f "$HOME/.claude/settings.json" ]
}

@test "install -y: short-flag alias works" {
  run bash -c "bash '$PP_ROOT/bin/install.sh' -y --no-sudo </dev/null"
  [ "$status" -eq 0 ]
}

@test "install --yes: skips OpenAI key prompt" {
  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping OpenAI key prompt"* ]] \
    || [[ "$output" == *"already configured"* ]]
}

@test "install --yes: preserves existing statusLine when one is present" {
  # Pre-stage a settings.json with a foreign statusLine.
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"statusLine":{"type":"command","command":"echo foreign-statusline","refreshInterval":5}}
JSON
  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  # Foreign statusLine preserved (default-N on the replace prompt).
  existing=$(jq -r '.statusLine.command' "$HOME/.claude/settings.json")
  [ "$existing" = "echo foreign-statusline" ]
  # But hooks were still installed.
  jq -e '[.hooks.UserPromptSubmit[]?.hooks[]?.command] | any(test("inject-monitor-insight"))' \
    "$HOME/.claude/settings.json" >/dev/null
}

# ============================================================
# --no-sudo
# ============================================================

@test "install --no-sudo: refuses sudo deps with exit 1 + manual command" {
  # Build a hermetic PATH that:
  #   - hides brew (so installer picks the apt-get + sudo path)
  #   - hides /usr/bin/jq (so check_or_install sees jq as absent)
  #   - provides apt-get (stub) so PKG_INSTALL_JQ resolves to the sudo path
  #   - provides bash + coreutils the installer needs (cat, dirname, date, etc.)
  #
  # We achieve this by symlinking ONLY the binaries the installer needs into
  # $fakebin, then setting PATH=$fakebin (no /usr/bin, no /bin).
  fakebin="$HOME/fakebin"
  mkdir -p "$fakebin"

  # Symlink the coreutils the installer touches. Resolve from the live PATH.
  for tool in bash sh cat mkdir cp mv rm date dirname sed tail stat find tr chmod stty mktemp ls pwd grep head; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$src" "$fakebin/$tool"
  done

  # Stub apt-get so `command -v apt-get` succeeds. Stub should never actually
  # be invoked under --no-sudo (we exit before then).
  cat > "$fakebin/apt-get" <<'APT'
#!/usr/bin/env bash
echo "apt-get called (this should not happen under --no-sudo)" >&2
exit 99
APT
  chmod +x "$fakebin/apt-get"

  # Pre-create CLAUDE_DIR so the "create dir?" prompt doesn't fire.
  mkdir -p "$CLAUDE_DIR"

  run env -i HOME="$HOME" CLAUDE_DIR="$CLAUDE_DIR" PATH="$fakebin" \
    bash "$PP_ROOT/bin/install.sh" --yes --no-sudo
  [ "$status" -eq 1 ]
  # Error message references the manual command + --no-sudo.
  [[ "$output" == *"--no-sudo"* ]]
  [[ "$output" == *"sudo apt-get"* ]]
}

@test "install --yes --no-sudo: jq-absent + apt-get-only host exits 1 cleanly" {
  # Same hermetic env as the previous test but with explicit assertion that
  # --yes does NOT bypass the --no-sudo refusal. Both flags applied together
  # must still exit 1 (refusing sudo > taking defaults).
  fakebin="$HOME/fakebin2"
  mkdir -p "$fakebin"
  for tool in bash sh cat mkdir cp mv rm date dirname sed tail stat find tr chmod stty mktemp ls pwd grep head; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$src" "$fakebin/$tool"
  done
  cat > "$fakebin/apt-get" <<'APT'
#!/usr/bin/env bash
exit 99
APT
  chmod +x "$fakebin/apt-get"
  mkdir -p "$CLAUDE_DIR"
  run env -i HOME="$HOME" CLAUDE_DIR="$CLAUDE_DIR" PATH="$fakebin" \
    bash "$PP_ROOT/bin/install.sh" --yes --no-sudo
  [ "$status" -eq 1 ]
  # --yes auto-took the default but --no-sudo still refused.
  [[ "$output" == *"--no-sudo"* ]]
}

# ============================================================
# --non-interactive
# ============================================================

@test "install --non-interactive: implies --yes AND --no-sudo" {
  run bash -c "bash '$PP_ROOT/bin/install.sh' --non-interactive </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-accepting"* ]] || [[ "$output" == *"Skipping"* ]] || [[ "$output" == *"--yes"* ]]
}

# ============================================================
# Audit log
# ============================================================

@test "install: writes audit log JSONL to expected path" {
  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  log="$HOME/.claude/pair-polymath/install.log"
  [ -f "$log" ]
  # Every line is valid JSON.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "$line" | jq -e . >/dev/null || { echo "Invalid JSONL: $line"; return 1; }
  done < "$log"
}

@test "install audit log: contains expected actions" {
  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  log="$HOME/.claude/pair-polymath/install.log"
  # Pull all action fields.
  actions=$(jq -r '.action' < "$log" | sort -u)
  echo "$actions" | grep -q 'install-start'
  echo "$actions" | grep -q 'install-complete'
  echo "$actions" | grep -q 'smoke-test'
  echo "$actions" | grep -q 'settings-merge'
}

@test "install --dry-run: writes NO audit log file" {
  run bash "$PP_ROOT/bin/install.sh" --dry-run --yes
  [ "$status" -eq 0 ]
  # Dry-run must be totally read-only — no log file either.
  [ ! -f "$HOME/.claude/pair-polymath/install.log" ]
}

# ============================================================
# Bare-install detection
# ============================================================

@test "install: bare-install detection prints migration steps" {
  mkdir -p "$HOME/.claude"
  echo "fake bare statusline" > "$HOME/.claude/statusline-command.sh"
  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bare-install"* ]]
  [[ "$output" == *"settings.json.pre-pp-bak"* ]]
  [[ "$output" == *"statusline-command.sh.pre-pp"* ]]
}

@test "install: bare-install counter bumps 0->1->2 across runs" {
  mkdir -p "$HOME/.claude"
  echo "fake" > "$HOME/.claude/statusline-command.sh"

  counter="$HOME/.claude/pair-polymath/cache/migration-requests.txt"
  [ ! -f "$counter" ]

  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$counter" ]
  [ "$(cat "$counter")" = "1" ]

  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  [ "$(cat "$counter")" = "2" ]
}

@test "install --dry-run: bare-install counter NOT bumped" {
  mkdir -p "$HOME/.claude"
  echo "fake" > "$HOME/.claude/statusline-command.sh"
  counter="$HOME/.claude/pair-polymath/cache/migration-requests.txt"

  run bash "$PP_ROOT/bin/install.sh" --dry-run --yes
  [ "$status" -eq 0 ]
  [ ! -f "$counter" ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [[ "$output" == *"counter"* ]]
}

@test "install: bare-install audit-log action emitted" {
  mkdir -p "$HOME/.claude"
  echo "fake" > "$HOME/.claude/statusline-command.sh"
  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  log="$HOME/.claude/pair-polymath/install.log"
  jq -e 'select(.action == "bare-install-detected")' < "$log" >/dev/null \
    || { echo "no bare-install-detected entry in log"; cat "$log"; return 1; }
}

# ============================================================
# Idempotence
# ============================================================

@test "install: two consecutive --yes runs leave one of each hook" {
  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]
  run bash -c "bash '$PP_ROOT/bin/install.sh' --yes --no-sudo </dev/null"
  [ "$status" -eq 0 ]

  settings="$HOME/.claude/settings.json"
  ups_count=$(jq '[.hooks.UserPromptSubmit[]?.hooks[]?.command | select(test("inject-monitor-insight"))] | length' "$settings")
  ptu_count=$(jq '[.hooks.PostToolUse[]?.hooks[]?.command      | select(test("cache-test-result"))] | length' "$settings")
  [ "$ups_count" = "1" ]
  [ "$ptu_count" = "1" ]
}
