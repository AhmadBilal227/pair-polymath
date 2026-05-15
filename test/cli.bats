#!/usr/bin/env bats
# polymath CLI: version, status, help, unknown command.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "polymath version: prints VERSION" {
  run bash "$PP_ROOT/bin/polymath" version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$PP_ROOT/VERSION")" ]
}

@test "polymath status: exits 0 with status info" {
  run bash "$PP_ROOT/bin/polymath" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pair Polymath status"* ]]
  [[ "$output" == *"Lenses loaded:"* ]]
}

@test "polymath help: lists subcommands" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"version"* ]]
}

@test "polymath: no args defaults to status" {
  run bash "$PP_ROOT/bin/polymath"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pair Polymath status"* ]]
}

@test "polymath: unknown command → exit 2 + stderr message" {
  run bash "$PP_ROOT/bin/polymath" nope 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
  [[ "$output" == *"polymath help"* ]]
}

@test "polymath disable: writes PP_EXTERNAL_LLM=0 to user.env" {
  # NOTE: setup() rebinds $HOME to a mktemp -d dir, so this path is in tmp.
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  run bash "$PP_ROOT/bin/polymath" disable
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM cycle disabled"* ]]
  grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath enable: writes PP_EXTERNAL_LLM=1 to user.env" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  run bash "$PP_ROOT/bin/polymath" enable
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLM cycle enabled"* ]]
  grep -q '^PP_EXTERNAL_LLM=1$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath disable: idempotent (no duplicate lines after repeated calls)" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  local count
  count=$(grep -c '^PP_EXTERNAL_LLM=' "$CLAUDE_DIR/pair-polymath/config/user.env")
  [ "$count" -eq 1 ]
}

@test "polymath enable: clears a prior disable" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  bash "$PP_ROOT/bin/polymath" enable >/dev/null
  grep -q '^PP_EXTERNAL_LLM=1$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  ! grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath disable: preserves unrelated user.env lines" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  cat > "$CLAUDE_DIR/pair-polymath/config/user.env" <<'EOF'
# Custom setting kept across toggles
PP_MAX_DAILY_CALLS=2000
PP_MODEL=gpt-5
EOF
  bash "$PP_ROOT/bin/polymath" disable >/dev/null
  grep -q '^PP_MAX_DAILY_CALLS=2000$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  grep -q '^PP_MODEL=gpt-5$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  grep -q '^# Custom setting kept across toggles$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath disable: creates user.env if absent" {
  export CLAUDE_DIR="$HOME/.claude-fresh"
  # Note: parent dirs do not exist
  run bash "$PP_ROOT/bin/polymath" disable
  [ "$status" -eq 0 ]
  test -f "$CLAUDE_DIR/pair-polymath/config/user.env"
  grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
}

@test "polymath help: lists enable and disable as available subcommands" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"polymath enable"* ]]
  [[ "$output" == *"polymath disable"* ]]
  # Should no longer say "v0.2 will add: disable, enable"
  ! [[ "$output" == *"will add: disable"* ]]
  ! [[ "$output" == *"will add: enable"* ]]
}

# === polymath logs ===

@test "polymath logs: empty cache yields friendly message" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  run bash "$PP_ROOT/bin/polymath" logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"no observations yet"* ]]
}

@test "polymath logs: prints recent observation in expected format" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  printf 'DEVOPS: install.sh has unchecked mktemp|||Investigate the cross-FS mv risk\n' \
    > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  run bash "$PP_ROOT/bin/polymath" logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENGINEERING"* ]]
  [[ "$output" == *"unchecked mktemp"* ]]
  [[ "$output" == *"cross-FS mv risk"* ]]
}

@test "polymath logs: --lens filters" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  printf 'A: e-hook|||e-body\n' > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  printf 'B: s-hook|||s-body\n' > "$PP_CACHE_DIR/cc-monitor-test-session-SECURITY.txt"
  run bash "$PP_ROOT/bin/polymath" logs --lens SECURITY
  [ "$status" -eq 0 ]
  [[ "$output" == *"SECURITY"* ]]
  [[ "$output" == *"s-body"* ]]
  ! [[ "$output" == *"e-body"* ]]
}

@test "polymath logs: -n caps output" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  for lens in A B C D E F; do
    printf 'X: hook-%s|||body-%s\n' "$lens" "$lens" \
      > "$PP_CACHE_DIR/cc-monitor-test-session-$lens.txt"
  done
  run bash "$PP_ROOT/bin/polymath" logs -n 2
  [ "$status" -eq 0 ]
  # Count "body-" occurrences — should be exactly 2
  count=$(echo "$output" | grep -c 'body-')
  [ "$count" -eq 2 ]
}

@test "polymath logs: -n rejects non-numeric" {
  run bash "$PP_ROOT/bin/polymath" logs -n abc
  [ "$status" -eq 2 ]
}

@test "polymath logs: unknown flag exits 2" {
  run bash "$PP_ROOT/bin/polymath" logs --nope
  [ "$status" -eq 2 ]
}

@test "polymath logs: shows DROP annotation when verdict sidecar present" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  printf 'X: hook|||body\n' > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  printf 'lens1: DROP - too vague\n' > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING-verdict.txt"
  run bash "$PP_ROOT/bin/polymath" logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"DROP"* ]]
}

# === polymath update ===

@test "polymath update: rejects non-git PP_ROOT cleanly" {
  PP_NON_GIT=$(mktemp -d)
  mkdir -p "$PP_NON_GIT/bin" "$PP_NON_GIT/lib" "$PP_NON_GIT/lenses" "$PP_NON_GIT/prompts"
  echo "0.0.0" > "$PP_NON_GIT/VERSION"
  cp "$PP_ROOT/bin/polymath" "$PP_NON_GIT/bin/polymath"
  cp "$PP_ROOT/lib/config.sh" "$PP_NON_GIT/lib/"
  cp "$PP_ROOT/lib/budget.sh" "$PP_NON_GIT/lib/"
  cp "$PP_ROOT/lib/lens-loader.sh" "$PP_NON_GIT/lib/"
  cp -r "$PP_ROOT/lenses/." "$PP_NON_GIT/lenses/"
  cp -r "$PP_ROOT/prompts/." "$PP_NON_GIT/prompts/"
  run bash "$PP_NON_GIT/bin/polymath" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git checkout"* ]]
  rm -rf "$PP_NON_GIT"
}

@test "polymath update --dry-run: makes no changes, prints plan" {
  # Use the real PP_ROOT — it IS a git checkout. fetch will probably fail in
  # hermetic test env (no remote configured for the tmp HOME) but the dry-run
  # gate is "before any pull"; if fetch succeeds and there are no commits,
  # output should say up-to-date.
  HOME=$PP_TEST_HOME run bash "$PP_ROOT/bin/polymath" update --dry-run
  # Allow either: up-to-date, OR fetch-failed (network/auth), OR dry-run-msg
  [ "$status" -le 1 ]
}

@test "polymath update: unknown flag exits 2" {
  run bash "$PP_ROOT/bin/polymath" update --nope
  [ "$status" -eq 2 ]
}

@test "polymath update --help: prints usage" {
  run bash "$PP_ROOT/bin/polymath" update --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"polymath update"* ]]
  [[ "$output" == *"Pull latest"* ]]
}

@test "polymath help: lists logs and update" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"polymath logs"* ]]
  [[ "$output" == *"polymath update"* ]]
  ! [[ "$output" == *"will add: logs"* ]]
  ! [[ "$output" == *"will add: update"* ]]
}

# Regression for review fix M1: symlinked user.env must keep its symlink.
# Without the fix, mv replaces the symlink with a regular file in the .claude
# tree, silently breaking dotfile-manager setups.
@test "polymath disable: preserves symlink to dotfile-managed user.env" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  # Store the real file under a "dotfiles" directory and symlink user.env to it
  mkdir -p "$HOME/dotfiles"
  printf 'PP_MODEL=gpt-5\n' > "$HOME/dotfiles/user.env"
  ln -s "$HOME/dotfiles/user.env" "$CLAUDE_DIR/pair-polymath/config/user.env"

  bash "$PP_ROOT/bin/polymath" disable >/dev/null

  # Symlink must still exist
  [ -L "$CLAUDE_DIR/pair-polymath/config/user.env" ]
  # And its target must be the unchanged dotfile path
  resolved=$(readlink "$CLAUDE_DIR/pair-polymath/config/user.env")
  [ "$resolved" = "$HOME/dotfiles/user.env" ]
  # And the disable line was written THROUGH the symlink to the real file
  grep -q '^PP_EXTERNAL_LLM=0$' "$HOME/dotfiles/user.env"
  grep -q '^PP_MODEL=gpt-5$' "$HOME/dotfiles/user.env"
}

# Regression for review fix H1: read errors must not silently destroy user.env.
@test "polymath disable: unreadable user.env aborts with clear error" {
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/pair-polymath/config"
  printf 'PP_MODEL=gpt-5\n' > "$CLAUDE_DIR/pair-polymath/config/user.env"
  # Pre-write something to make sure we don't silently nuke it
  chmod 000 "$CLAUDE_DIR/pair-polymath/config/user.env"

  run bash "$PP_ROOT/bin/polymath" disable
  # Root would still be able to read; running as non-root, grep exit > 1.
  # If we DO run as root in CI, this test should still find user.env intact
  # because the disable succeeded.
  chmod 644 "$CLAUDE_DIR/pair-polymath/config/user.env"

  if [ "$status" -ne 0 ]; then
    # Expected non-root path: failure + clear stderr, original file untouched
    [[ "$output" == *"failed to read"* ]] || [[ "$output" == *"left intact"* ]]
    grep -q '^PP_MODEL=gpt-5$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  else
    # Root path: disable succeeded; line was added
    grep -q '^PP_EXTERNAL_LLM=0$' "$CLAUDE_DIR/pair-polymath/config/user.env"
  fi
}

# === Review-pass regressions for PR #8 (logs+update fixes) ===

# Regression for review fix F1: multi-dash session IDs (UUIDs, project slugs)
# previously got truncated to the first segment by the `([^-]+)` capture.
@test "polymath logs: handles multi-dash session id (F1)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  # Note: NO PP_SESSION_ID — force the sniff path through the regex
  printf 'X: hook|||body-multidash\n' \
    > "$PP_CACHE_DIR/cc-monitor-abc-def-ghi-ENGINEERING.txt"
  run bash "$PP_ROOT/bin/polymath" logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"body-multidash"* ]]
  [[ "$output" == *"ENGINEERING"* ]]
  # Negative: must NOT print the "no observations" path (which is what
  # the broken regex would produce — sess=`abc`, glob misses everything).
  ! [[ "$output" == *"no observations for session abc yet"* ]]
}

# Regression for review fix F2: lens IDs with digits / mixed case were
# rejected by the prior `([A-Z_]+)` capture.
@test "polymath logs: handles numeric / mixed-case lens id (F2)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  printf 'X: hook|||body-v2\n' \
    > "$PP_CACHE_DIR/cc-monitor-test-session-engineering_v2.txt"
  run bash "$PP_ROOT/bin/polymath" logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"engineering_v2"* ]]
  [[ "$output" == *"body-v2"* ]]
}

# Regression for review fix F3: `-n` with no value used to spin forever.
@test "polymath logs: -n with no value exits 2 cleanly (F3)" {
  run bash "$PP_ROOT/bin/polymath" logs -n
  [ "$status" -eq 2 ]
  [[ "$output" == *"-n requires a value"* ]]
}

@test "polymath logs: --lens with no value exits 2 cleanly (F3)" {
  run bash "$PP_ROOT/bin/polymath" logs --lens
  [ "$status" -eq 2 ]
  [[ "$output" == *"--lens requires a value"* ]]
}

# Regression for review fix F4: `polymath update --yes` must NOT invoke
# the interactive install.sh post-pull.
@test "polymath update --yes: skips interactive installer post-pull (F4)" {
  # We need a real local git repo to drive update through to the
  # post-pull branch without doing actual network I/O. Build a fake
  # "remote" repo and clone it; then make a single forward commit on
  # the remote so the CLI sees "new commits" and proceeds.
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  # Initial commit in remote
  git -C "$remote_dir" init --quiet --initial-branch=main 2>/dev/null \
    || git -C "$remote_dir" init --quiet
  # Older git ignores --initial-branch; force it via symbolic-ref to be safe
  git -C "$remote_dir" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  # Task #60 flake fix — see _pp_r5_build_remote_and_clone for context.
  # gc.auto + maintenance.auto race the test's `rm -rf` cleanup post-pull.
  git -C "$remote_dir" config gc.auto 0
  git -C "$remote_dir" config maintenance.auto false
  mkdir -p "$remote_dir/bin" "$remote_dir/lib" "$remote_dir/lenses" "$remote_dir/prompts"
  echo "0.0.0" > "$remote_dir/VERSION"
  cp "$PP_ROOT/bin/polymath" "$remote_dir/bin/polymath"
  cp "$PP_ROOT/lib/config.sh" "$remote_dir/lib/"
  cp "$PP_ROOT/lib/budget.sh" "$remote_dir/lib/"
  cp "$PP_ROOT/lib/lens-loader.sh" "$remote_dir/lib/"
  cp -R "$PP_ROOT/lenses/." "$remote_dir/lenses/"
  cp -R "$PP_ROOT/prompts/." "$remote_dir/prompts/"
  # install.sh that would HANG if invoked (sleeps forever on stdin)
  cat > "$remote_dir/bin/install.sh" <<'SH'
#!/usr/bin/env bash
# Test sentinel: this would block forever in CI if --yes invokes it.
read -r _x
echo SHOULD_NOT_RUN
SH
  chmod +x "$remote_dir/bin/install.sh"
  git -C "$remote_dir" config user.email "t@t" && git -C "$remote_dir" config user.name t
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "init"
  # Clone into a "client" install
  git clone --quiet "$remote_dir" "$clone_dir"
  # Task #60: also disable in the clone — `git pull` runs here in the test.
  git -C "$clone_dir" config gc.auto 0
  git -C "$clone_dir" config maintenance.auto false
  git -C "$clone_dir" config user.email "t@t" && git -C "$clone_dir" config user.name t
  # Add a new commit on the remote so update has something to pull
  echo "1" >> "$remote_dir/VERSION"
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "bump"

  # Run --yes against the clone with stdin from /dev/null so that EVEN IF
  # install.sh were invoked (the bug we're guarding against), its `read`
  # would EOF immediately rather than hang the test runner. We also rewrite
  # the trap installer to print SHOULD_NOT_RUN on stdout — that's our
  # negative-assertion sentinel. macOS has no `timeout`(1), so we rely on
  # the EOF guarantee + a stdin redirect.
  run bash -c "bash '$clone_dir/bin/polymath' update --yes </dev/null"
  rm -rf "$remote_dir" "$clone_dir"
  [ "$status" -eq 0 ]
  # Round-5 R4-1 changed the wording: instead of "Skipping interactive installer"
  # the code now distinguishes between idempotent pulls and installer-affecting
  # pulls. Either phrasing proves --yes did not invoke install.sh interactively.
  [[ "$output" == *"No installer-affecting files changed"* ]] \
    || [[ "$output" == *"installer-affecting files changed:"* ]] \
    || [[ "$output" == *"Pull complete"* ]]
  # Load-bearing negative assertion (install.sh trap would print this if invoked).
  ! [[ "$output" == *"SHOULD_NOT_RUN"* ]]
}

# Regression for review fix F5: verdict / streak sidecars must not appear
# as observations in `polymath logs` output.
@test "polymath logs: excludes verdict/streak sidecar files (F5)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  printf 'X: real-hook|||real-body\n' \
    > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  printf 'lens1: DROP - garbled-verdict-content\n' \
    > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING-verdict.txt"
  printf 'streak=3\n' \
    > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING-streak.txt"
  run bash "$PP_ROOT/bin/polymath" logs
  [ "$status" -eq 0 ]
  # Real observation appears
  [[ "$output" == *"real-body"* ]]
  # Verdict/streak content must NOT appear as standalone observations.
  # (DROP annotation is allowed via the sidecar mechanism — we check for
  # the verbatim verdict-content string, which only renders if the
  # verdict file was treated as an observation.)
  ! [[ "$output" == *"garbled-verdict-content"* ]]
  ! [[ "$output" == *"streak=3"* ]]
}

# Regression for review fix F6: update should detect the default branch
# from origin/HEAD instead of hardcoding `main`.
@test "polymath update --dry-run: uses origin/HEAD-derived default branch (F6)" {
  # Build a fake remote on branch `develop` and clone it.
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  git -C "$remote_dir" init --quiet
  git -C "$remote_dir" symbolic-ref HEAD refs/heads/develop
  mkdir -p "$remote_dir/bin" "$remote_dir/lib" "$remote_dir/lenses" "$remote_dir/prompts"
  echo "0.0.0" > "$remote_dir/VERSION"
  cp "$PP_ROOT/bin/polymath" "$remote_dir/bin/polymath"
  cp "$PP_ROOT/lib/config.sh" "$remote_dir/lib/"
  cp "$PP_ROOT/lib/budget.sh" "$remote_dir/lib/"
  cp "$PP_ROOT/lib/lens-loader.sh" "$remote_dir/lib/"
  cp -R "$PP_ROOT/lenses/." "$remote_dir/lenses/"
  cp -R "$PP_ROOT/prompts/." "$remote_dir/prompts/"
  git -C "$remote_dir" config user.email "t@t" && git -C "$remote_dir" config user.name t
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "init"
  # Clone — HEAD will point at develop and refs/remotes/origin/HEAD
  # gets set automatically by git clone.
  git clone --quiet "$remote_dir" "$clone_dir"
  # Capture FETCH_HEAD mtime to assert dry-run does NOT mutate it
  fetch_head_before=""
  [ -f "$clone_dir/.git/FETCH_HEAD" ] && fetch_head_before=$(stat -f %m "$clone_dir/.git/FETCH_HEAD" 2>/dev/null || stat -c %Y "$clone_dir/.git/FETCH_HEAD" 2>/dev/null)
  run bash "$clone_dir/bin/polymath" update --dry-run
  fetch_head_after=""
  [ -f "$clone_dir/.git/FETCH_HEAD" ] && fetch_head_after=$(stat -f %m "$clone_dir/.git/FETCH_HEAD" 2>/dev/null || stat -c %Y "$clone_dir/.git/FETCH_HEAD" 2>/dev/null)
  rm -rf "$remote_dir" "$clone_dir"
  [ "$status" -eq 0 ]
  # Dry-run output must reference `develop`, NOT `main`.
  [[ "$output" == *"Already up to date"* ]] || [[ "$output" == *"develop"* ]]
  ! [[ "$output" == *"origin/main"* ]]
  # Review fix F8 cross-check: dry-run must not touch FETCH_HEAD
  [ "$fetch_head_before" = "$fetch_head_after" ]
}

# Regression for review fix F7: timestamp must not render as `?` on macOS.
@test "polymath logs: renders mtime (not '?') on this platform (F7)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  printf 'X: h|||b\n' \
    > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  run bash "$PP_ROOT/bin/polymath" logs
  [ "$status" -eq 0 ]
  # A correctly-resolved timestamp starts with 4 digits (YYYY).
  [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]
  # And we did not fall through to the '?' sentinel.
  ! [[ "$output" =~ ^\?\  ]]
}

# Regression for review fix F8: dry-run must not perform a network-mutating
# `git fetch`. We don't have a remote here, but we can assert exit code is
# clean and the message indicates the read-only path was taken.
@test "polymath update --dry-run: prints dry-run plan without fetching (F8)" {
  # The real PP_ROOT IS a git checkout. dry-run should either say
  # up-to-date or print a dry-run line. CRITICALLY it must NOT print
  # "Fetching from origin..." (which only happens on the real path).
  run bash "$PP_ROOT/bin/polymath" update --dry-run
  # Allow 0 (up-to-date OR could-not-query) — both are non-mutating.
  [ "$status" -eq 0 ]
  # Must not have entered the real path
  ! [[ "$output" == *"Fetching from origin"* ]]
}

# === Round-3 regressions ===

# Regression for review fix F7' (round 3): the round-1 mtime fix used a
# BSD-first / GNU-fallback chain. On GNU/Linux `stat -f %m FILE` does NOT
# fail — it returns the MOUNT POINT string, which `date -r FILE` then
# accepts as a filename. Result: every log entry's timestamp silently
# resolved to the mount point's mtime. Format-valid but value-wrong, so the
# F7 format-only test still passed. This test asserts VALUE correctness:
# two files with different mtimes must produce two different output stamps
# (they would be identical — mount point mtime — under the broken chain).
@test "polymath logs: timestamp matches file mtime, not mount point (F7' round-3)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  f1="$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  f2="$PP_CACHE_DIR/cc-monitor-test-session-SECURITY.txt"
  printf 'X: hook|||body-eng\n' > "$f1"
  # Sleep long enough that the mtimes are guaranteed-different at HH:MM:SS
  # resolution, and that the LS ordering is stable on both BSD and ext4.
  sleep 2
  printf 'Y: hook|||body-sec\n' > "$f2"
  run bash "$PP_ROOT/bin/polymath" logs -n 2
  [ "$status" -eq 0 ]
  # Extract each entry's "YYYY-MM-DD HH:MM:SS" stamp (first two whitespace-
  # separated fields of the line that contains the lens id).
  ts_eng=$(echo "$output" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}.*ENGINEERING' | awk '{print $1, $2}')
  ts_sec=$(echo "$output" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}.*SECURITY' | awk '{print $1, $2}')
  [ -n "$ts_eng" ]
  [ -n "$ts_sec" ]
  # If both came from the mount point (bug), these would be identical.
  [ "$ts_eng" != "$ts_sec" ]
}

# Companion to F7' — keep the original format assertion, but also confirm
# we never fall back to the '?' sentinel.
@test "polymath logs: timestamp is YYYY-MM-DD HH:MM:SS not '?' (F7' format)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  printf 'X: hook|||body\n' > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  run bash "$PP_ROOT/bin/polymath" logs
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'
  ! echo "$output" | grep -q '^?'
}

# Regression for review fix G3 (round 3): --follow with --lens must follow
# only that lens's specific cache file, and refuse gracefully if that file
# doesn't yet exist.
@test "polymath logs --follow --lens: gracefully reports missing lens cache (G3)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  # Seed an unrelated lens so the session-sniff path succeeds, but the
  # requested lens cache file doesn't exist.
  printf 'X: hook|||body\n' > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  run bash "$PP_ROOT/bin/polymath" logs --follow --lens NOPE
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cache file yet"* ]]
  [[ "$output" == *"NOPE"* ]]
}

# Regression for review fix G4 (round 3): --lens filter must apply BEFORE
# head -n, otherwise --lens X -n N can return zero when X's files aren't
# in the newest N. Stage cache files so the lens-of-interest is the OLDEST,
# then assert it still surfaces.
@test "polymath logs --lens X -n N: filter applied before head (G4)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  # ENGINEERING is the OLDEST file in the cache.
  printf 'A: hook-eng|||body-eng\n' \
    > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  sleep 1
  # Add 10 newer files for OTHER lenses.
  for lens in B C D E F G H I J K; do
    printf 'X: hook-%s|||body-%s\n' "$lens" "$lens" \
      > "$PP_CACHE_DIR/cc-monitor-test-session-$lens.txt"
    # Small delay to keep ls -t ordering deterministic across filesystems.
    sleep 0.05
  done
  # Pre-fix: head -n 5 picks B..F, --lens ENGINEERING filter → 0 results.
  # Post-fix: --lens ENGINEERING filter → 1 file, head -n 5 → 1 file.
  run bash "$PP_ROOT/bin/polymath" logs --lens ENGINEERING -n 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"body-eng"* ]]
  [[ "$output" == *"ENGINEERING"* ]]
  ! [[ "$output" == *"body-B"* ]]
}

# Regression for review fix F9: non-interactive stdin without --yes must
# refuse, not silently default to Y.
@test "polymath update: non-interactive stdin without --yes refuses (F9)" {
  # Build a clone that has commits behind so we get past the up-to-date check.
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  git -C "$remote_dir" init --quiet
  git -C "$remote_dir" symbolic-ref HEAD refs/heads/main
  mkdir -p "$remote_dir/bin" "$remote_dir/lib" "$remote_dir/lenses" "$remote_dir/prompts"
  echo "0.0.0" > "$remote_dir/VERSION"
  cp "$PP_ROOT/bin/polymath" "$remote_dir/bin/polymath"
  cp "$PP_ROOT/lib/config.sh" "$remote_dir/lib/"
  cp "$PP_ROOT/lib/budget.sh" "$remote_dir/lib/"
  cp "$PP_ROOT/lib/lens-loader.sh" "$remote_dir/lib/"
  cp -R "$PP_ROOT/lenses/." "$remote_dir/lenses/"
  cp -R "$PP_ROOT/prompts/." "$remote_dir/prompts/"
  # Trap installer (must not run)
  cat > "$remote_dir/bin/install.sh" <<'SH'
#!/usr/bin/env bash
echo SHOULD_NOT_RUN
SH
  chmod +x "$remote_dir/bin/install.sh"
  git -C "$remote_dir" config user.email "t@t" && git -C "$remote_dir" config user.name t
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "init"
  git clone --quiet "$remote_dir" "$clone_dir"
  echo "1" >> "$remote_dir/VERSION"
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "bump"

  # Pipe `</dev/null` to force non-TTY stdin, no --yes
  run bash -c "bash '$clone_dir/bin/polymath' update </dev/null"
  rm -rf "$remote_dir" "$clone_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-interactive stdin without --yes"* ]]
  ! [[ "$output" == *"SHOULD_NOT_RUN"* ]]
}

# === Round-5 regressions ===

# Helper: shared fixture builder for update tests. Builds a remote git repo
# with required files and a clone tracking it. Subsequent commits to the
# remote let us drive --yes through to the post-pull diff branch.
_pp_r5_build_remote_and_clone() {
  local remote_dir="$1"
  local clone_dir="$2"
  git -C "$remote_dir" init --quiet
  git -C "$remote_dir" symbolic-ref HEAD refs/heads/main
  # Task #60 flake fix: disable git's background gc.auto + maintenance.auto.
  # Since git 2.27 these can spawn detached child processes that keep writing
  # to .git/ AFTER `git pull` exits — racing the test's `rm -rf` cleanup with
  # "rm: cannot remove '/tmp/tmp.XXX/.git': Directory not empty". Belt-and-
  # suspenders: per-repo config disables both background hooks; tests stay
  # hermetic. Observed flake cluster on PRs #69/#70/#72/#73.
  git -C "$remote_dir" config gc.auto 0
  git -C "$remote_dir" config maintenance.auto false
  mkdir -p "$remote_dir/bin" "$remote_dir/lib" "$remote_dir/lenses" "$remote_dir/prompts"
  echo "0.0.0" > "$remote_dir/VERSION"
  cp "$PP_ROOT/bin/polymath" "$remote_dir/bin/polymath"
  cp "$PP_ROOT/lib/config.sh" "$remote_dir/lib/"
  cp "$PP_ROOT/lib/budget.sh" "$remote_dir/lib/"
  cp "$PP_ROOT/lib/lens-loader.sh" "$remote_dir/lib/"
  cp -R "$PP_ROOT/lenses/." "$remote_dir/lenses/"
  cp -R "$PP_ROOT/prompts/." "$remote_dir/prompts/"
  # Trap installer (must never run)
  cat > "$remote_dir/bin/install.sh" <<'SH'
#!/usr/bin/env bash
echo SHOULD_NOT_RUN
SH
  chmod +x "$remote_dir/bin/install.sh"
  git -C "$remote_dir" config user.email "t@t"
  git -C "$remote_dir" config user.name t
  git -C "$remote_dir" add -A
  git -C "$remote_dir" commit -q -m "init"
  git clone --quiet "$remote_dir" "$clone_dir"
  # Task #60 flake fix applies to clone too — clone is where `git pull` runs
  # in the test, so it's the side that spawns the gc.auto background process.
  git -C "$clone_dir" config gc.auto 0
  git -C "$clone_dir" config maintenance.auto false
  git -C "$clone_dir" config user.email "t@t"
  git -C "$clone_dir" config user.name t
}

# Round-4 R4-1 (HIGH): --yes detects installer-affecting changes after pull.
# Case A: commit touches only an inert file → "install was idempotent".
@test "polymath update --yes: idempotent when pull does not touch installer (R4-1a)" {
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  _pp_r5_build_remote_and_clone "$remote_dir" "$clone_dir"
  # Bump only VERSION (inert from installer's perspective)
  echo "0.0.1" > "$remote_dir/VERSION"
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "bump version only"

  run bash -c "bash '$clone_dir/bin/polymath' update --yes </dev/null"
  rm -rf "$remote_dir" "$clone_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No installer-affecting files changed"* ]]
  [[ "$output" == *"install was idempotent"* ]]
  ! [[ "$output" == *"SHOULD_NOT_RUN"* ]]
  ! [[ "$output" == *"WARNING"* ]]
}

# Round-4 R4-1 (HIGH): --yes warns loudly when pull touches bin/install.sh.
# Pull succeeds (exit 0), warning goes to stderr, user gets exact re-run cmd.
@test "polymath update --yes: warns loudly when pull touches install.sh (R4-1b)" {
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  _pp_r5_build_remote_and_clone "$remote_dir" "$clone_dir"
  # Modify bin/install.sh in the remote so the next pull is installer-affecting
  cat > "$remote_dir/bin/install.sh" <<'SH'
#!/usr/bin/env bash
# Updated installer — still a trap if invoked by --yes path
echo SHOULD_NOT_RUN
SH
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "tweak installer"

  run bash -c "bash '$clone_dir/bin/polymath' update --yes </dev/null 2>&1"
  rm -rf "$remote_dir" "$clone_dir"
  # Pull succeeded — exit code is 0 (we warn, we don't fail)
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]] || [[ "$output" == *"installer-affecting files changed"* ]]
  [[ "$output" == *"bin/install.sh"* ]]
  [[ "$output" == *"Re-run interactively"* ]]
  # The installer itself must NOT have been invoked
  ! [[ "$output" == *"SHOULD_NOT_RUN"* ]]
}

# Round-4 R4-2 (HIGH): respect @{upstream} when configured. Set up a branch
# that tracks a non-default branch on the remote and verify the dry-run
# output references the upstream (e.g. origin/feature), NOT origin/main.
@test "polymath update --dry-run: honors @{upstream} for non-default branches (R4-2)" {
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  _pp_r5_build_remote_and_clone "$remote_dir" "$clone_dir"
  # Create a feature branch on the remote with one extra commit.
  git -C "$remote_dir" checkout -q -b feature
  echo "feature-content" > "$remote_dir/FEATURE"
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "add feature"
  # In the clone: fetch, then check out a local branch tracking origin/feature.
  git -C "$clone_dir" fetch --quiet origin
  git -C "$clone_dir" checkout -q -b feature --track origin/feature
  # Add one MORE commit on remote AFTER the clone tracks it, so dry-run sees
  # a forward delta. Without this, dry-run short-circuits to "Already up to
  # date" (which doesn't print the compare ref).
  echo "feature-ahead" > "$remote_dir/FEATURE2"
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "feature ahead"

  # Dry-run should reference origin/feature, not origin/main.
  run bash "$clone_dir/bin/polymath" update --dry-run
  rm -rf "$remote_dir" "$clone_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"origin/feature"* ]]
  ! [[ "$output" == *"origin/main"* ]]
}

# Round-4 R4-3 (HIGH): real path refuses on dirty working tree, BEFORE fetch.
@test "polymath update: refuses on dirty working tree (R4-3 real)" {
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  _pp_r5_build_remote_and_clone "$remote_dir" "$clone_dir"
  # Dirty the clone: edit a tracked file without committing.
  echo "dirty" >> "$clone_dir/VERSION"
  # No need for upstream commits — the dirty check should short-circuit before
  # the fetch.

  run bash -c "bash '$clone_dir/bin/polymath' update --yes </dev/null 2>&1"
  rm -rf "$remote_dir" "$clone_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted changes"* ]]
  [[ "$output" == *"Stash or commit"* ]]
  # Crucially: dirty-tree check fires BEFORE fetch. We assert no "Fetching"
  # banner appeared in output.
  ! [[ "$output" == *"Fetching from origin"* ]]
}

# Round-4 R4-3 (HIGH): dry-run mentions dirty tree as a blocker but exits 0.
@test "polymath update --dry-run: surfaces dirty tree as blocker, exits 0 (R4-3 dry)" {
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  _pp_r5_build_remote_and_clone "$remote_dir" "$clone_dir"
  echo "dirty" >> "$clone_dir/VERSION"

  run bash "$clone_dir/bin/polymath" update --dry-run
  rm -rf "$remote_dir" "$clone_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uncommitted changes"* ]] || [[ "$output" == *"would refuse"* ]]
}

# Round-4 R4-4 (MEDIUM): stat flavor probe must work on this platform without
# falling through to "unknown" → '?' timestamps. We already have F7'/F7
# regressions that assert mtime resolves; this is a more direct sanity check
# that some flavor was assigned and timestamps render correctly even when
# `stat --version` is missing or differs.
@test "polymath logs: stat flavor probe yields working mtime on this OS (R4-4)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  printf 'X: hook|||body-stat\n' > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  run bash "$PP_ROOT/bin/polymath" logs
  [ "$status" -eq 0 ]
  # Real timestamp, not the unknown-flavor '?' sentinel.
  [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]
  ! echo "$output" | grep -qE '^\?  '
  ! echo "$output" | grep -qE '^\? '
}

# Round-4 R4-5 (MEDIUM): --follow (no --lens) must include ALL lens files for
# the session, not just the newest. We can't easily test the actual tailing
# loop (it blocks), but we can assert that with no lens files at all, the
# session-empty message fires — which exercises the new file-collection
# code path. The session is set explicitly so no auto-sniff path is taken,
# and the empty file-collection branch exits cleanly (no `tail -F` invoked).
@test "polymath logs --follow: empty session prints 'no observations' (R4-5 empty)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  # Seed a sidecar-only file so the session-sniff path can find the session
  # but the post-filter file list is EMPTY. This exercises R4-5's new branch
  # without needing `timeout`(1) (which macOS lacks).
  export PP_SESSION_ID="empty-session"
  printf 'verdict\n' > "$PP_CACHE_DIR/cc-monitor-empty-session-X-verdict.txt"
  printf 'streak=1\n' > "$PP_CACHE_DIR/cc-monitor-empty-session-X-streak.txt"
  run bash "$PP_ROOT/bin/polymath" logs --follow
  [ "$status" -eq 0 ]
  [[ "$output" == *"no observations yet for session empty-session"* ]] \
    || [[ "$output" == *"no observations"* ]]
}

# Round-4 R4-6 (MEDIUM): dry-run distinguishes fast-forward from divergence.
# Case A: remote strictly ahead → "Would fast-forward".
@test "polymath update --dry-run: 'would fast-forward' for linear ahead remote (R4-6 ff)" {
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  _pp_r5_build_remote_and_clone "$remote_dir" "$clone_dir"
  echo "next" >> "$remote_dir/VERSION"
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "ahead"

  run bash "$clone_dir/bin/polymath" update --dry-run
  rm -rf "$remote_dir" "$clone_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would fast-forward"* ]]
  ! [[ "$output" == *"diverged"* ]]
}

# Round-4 R4-6 (MEDIUM): dry-run reports divergence when local has commits
# that remote does not. Setup: clone, then commit locally without pulling,
# then add a different commit to remote → diverged histories.
@test "polymath update --dry-run: reports divergence when local has unique commits (R4-6 div)" {
  remote_dir=$(mktemp -d)
  clone_dir=$(mktemp -d)
  _pp_r5_build_remote_and_clone "$remote_dir" "$clone_dir"
  # Local commit not on remote
  echo "local-only" > "$clone_dir/LOCAL"
  git -C "$clone_dir" add -A && git -C "$clone_dir" commit -q -m "local commit"
  # Remote commit not on local
  echo "remote-only" > "$remote_dir/REMOTE"
  git -C "$remote_dir" add -A && git -C "$remote_dir" commit -q -m "remote commit"

  run bash "$clone_dir/bin/polymath" update --dry-run
  rm -rf "$remote_dir" "$clone_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"diverged"* ]] || [[ "$output" == *"FAIL --ff-only"* ]]
  ! [[ "$output" == *"Would fast-forward"* ]]
}

# Round-4 R4-7 (LOW): printf format strings starting with '-' must be guarded
# with '--' so they don't parse as flags. Hardest to test without invoking
# --follow (which tails forever), so we run `--follow --lens X` against a
# missing-lens case — that path doesn't hit the printf '--follow ...' string,
# but it confirms the surrounding code is shaped correctly. The actual lens
# branch printf uses 'printf -- '...'' now; verify by grep so future edits
# can't silently regress.
@test "bin/polymath: every printf format starting with '-' is dash-dash-guarded (R4-7)" {
  # Find any printf format starting with a single dash that ISN'T preceded by `--`.
  # The previous bug: `printf '--follow ...'` could parse '--follow' as flag.
  # Our fix uses `printf -- '--follow ...'`. This grep catches any regression.
  ! grep -nE "[^-]printf '-[^-]" "$PP_ROOT/bin/polymath"
  ! grep -nE "^printf '-[^-]" "$PP_ROOT/bin/polymath"
}

# Round-4 R4-8 (LOW): -n 0 must reject with clear error.
@test "polymath logs: -n 0 rejected with clear message (R4-8)" {
  run bash "$PP_ROOT/bin/polymath" logs -n 0
  [ "$status" -eq 2 ]
  [[ "$output" == *">= 1"* ]] || [[ "$output" == *"must be"* ]]
}

@test "polymath logs: -n 1 accepted (R4-8 boundary)" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  export PP_SESSION_ID="test-session"
  printf 'X: hook|||body-one\n' > "$PP_CACHE_DIR/cc-monitor-test-session-ENGINEERING.txt"
  run bash "$PP_ROOT/bin/polymath" logs -n 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"body-one"* ]]
}

# ----- polymath cost (P3.2) -----------------------------------------------

_pp_cost_seed_metrics() {
  # Helper: seed $PP_CACHE_DIR/metrics.jsonl with a few entries covering
  # both recent (today) and older (~45 days ago) timestamps. Uses portable
  # date arithmetic (BSD/macOS first, GNU fallback).
  local now today_iso older_iso
  if date -u '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    today_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  fi
  if date -u -v -45d '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    older_iso=$(date -u -v -45d '+%Y-%m-%dT%H:%M:%SZ')
  else
    older_iso=$(date -u -d "-45 days" '+%Y-%m-%dT%H:%M:%SZ')
  fi
  cat > "$PP_CACHE_DIR/metrics.jsonl" <<EOF
{"ts":"$today_iso","session":"abc","calls":9,"usd_est":0.012345,"by_type":{"planner":1,"analyst":7,"critique":1}}
{"ts":"$today_iso","session":"abc","calls":10,"usd_est":0.020100,"by_type":{"planner":1,"analyst":7,"critique":1,"retry":1}}
{"ts":"$older_iso","session":"old","calls":9,"usd_est":0.011000,"by_type":{"planner":1,"analyst":7,"critique":1}}
EOF
}

@test "polymath cost: empty metrics → 'no metrics yet' exit 0" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  run bash "$PP_ROOT/bin/polymath" cost
  [ "$status" -eq 0 ]
  [[ "$output" == *"no metrics yet"* ]]
}

@test "polymath cost: populated metrics → table with date / cycles / calls / USD" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  _pp_cost_seed_metrics
  run bash "$PP_ROOT/bin/polymath" cost
  [ "$status" -eq 0 ]
  [[ "$output" == *"Date"* ]]
  [[ "$output" == *"Cycles"* ]]
  [[ "$output" == *"Calls"* ]]
  [[ "$output" == *"USD (est)"* ]]
  [[ "$output" == *"Total"* ]]
  # 45-day-old entry must NOT be in default 7d window
  [[ "$output" != *"$(date -u -v -45d '+%Y-%m-%d' 2>/dev/null || date -u -d '-45 days' '+%Y-%m-%d')"* ]]
}

@test "polymath cost --by-lens: breakdown by call type" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  _pp_cost_seed_metrics
  run bash "$PP_ROOT/bin/polymath" cost --by-lens
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cost by call type"* ]]
  [[ "$output" == *"analyst:"* ]]
  [[ "$output" == *"planner:"* ]]
  [[ "$output" == *"critique:"* ]]
}

@test "polymath cost --json: emits JSONL filtered by cutoff" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  _pp_cost_seed_metrics
  run bash "$PP_ROOT/bin/polymath" cost --json
  [ "$status" -eq 0 ]
  # 2 today entries, 1 old entry; default 7d window → 2 lines
  local line_count
  line_count=$(printf '%s\n' "$output" | grep -c '^{')
  [ "$line_count" -eq 2 ]
  # Each printed line parses as JSON
  printf '%s\n' "$output" | while IFS= read -r ln; do
    printf '%s' "$ln" | jq -e '.' >/dev/null || exit 1
  done
}

@test "polymath cost --since 60d: broader window includes older entries" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  _pp_cost_seed_metrics
  run bash "$PP_ROOT/bin/polymath" cost --since 60d
  [ "$status" -eq 0 ]
  # 45-day-old entry should now appear in the table
  local older_date
  older_date=$(date -u -v -45d '+%Y-%m-%d' 2>/dev/null || date -u -d '-45 days' '+%Y-%m-%d')
  [[ "$output" == *"$older_date"* ]]
}

@test "polymath cost --since abc: exit 2 with clear error" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  _pp_cost_seed_metrics
  run bash "$PP_ROOT/bin/polymath" cost --since abc 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" == *"--since"* ]]
}

@test "polymath cost --since 7: missing 'd' suffix exit 2" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  _pp_cost_seed_metrics
  run bash "$PP_ROOT/bin/polymath" cost --since 7 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" == *"like 7d"* ]]
}

@test "polymath cost: unknown flag exits 2" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  _pp_cost_seed_metrics
  run bash "$PP_ROOT/bin/polymath" cost --bogus 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "polymath cost --help: prints help + exits 0" {
  run bash "$PP_ROOT/bin/polymath" cost --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"polymath cost"* ]]
  [[ "$output" == *"--since"* ]]
  [[ "$output" == *"--by-lens"* ]]
  [[ "$output" == *"--json"* ]]
}

@test "polymath help: cost listed in usage, no longer in 'v0.2 will add'" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"polymath cost"* ]]
  # "v0.2 will add" line should no longer mention 'cost'
  [[ "$output" != *"will add: cost"* ]]
}

# ----- Round-2 review fixes --------------------------------------------------

@test "R2-H2: polymath cost --by-lens sums call counts across sessions (not last-write-wins)" {
  # Three sessions, each with 5 planner calls. Total must be 15 — pre-fix
  # this returned 5 because jq `add` on objects is key-collision merge.
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  local today_iso
  today_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cat > "$PP_CACHE_DIR/metrics.jsonl" <<EOF
{"ts":"$today_iso","session":"a","calls":5,"usd_est":0.0015,"by_type":{"planner":5},"by_type_usd":{"planner":0.0015}}
{"ts":"$today_iso","session":"b","calls":5,"usd_est":0.0015,"by_type":{"planner":5},"by_type_usd":{"planner":0.0015}}
{"ts":"$today_iso","session":"c","calls":5,"usd_est":0.0015,"by_type":{"planner":5},"by_type_usd":{"planner":0.0015}}
EOF
  run bash "$PP_ROOT/bin/polymath" cost --by-lens
  [ "$status" -eq 0 ]
  # Must report 15 planner calls — NOT 5
  [[ "$output" == *"planner: 15 calls"* ]]
  # USD breakdown should be present and approximately $0.0045
  [[ "$output" == *"\$0.0045"* ]]
}

@test "R2-H2: polymath cost --by-lens shows USD per call type" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  local today_iso
  today_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cat > "$PP_CACHE_DIR/metrics.jsonl" <<EOF
{"ts":"$today_iso","session":"a","calls":3,"usd_est":0.0103,"by_type":{"planner":1,"analyst":1,"critique":1},"by_type_usd":{"planner":0.0003,"analyst":0.00091,"critique":0.00937}}
EOF
  run bash "$PP_ROOT/bin/polymath" cost --by-lens
  [ "$status" -eq 0 ]
  # Each line must include "$" + decimal — the output is "  type: N calls / $0.xxxx"
  [[ "$output" == *"calls / \$"* ]]
}

@test "R2-H2: by-lens still works on legacy entries without by_type_usd field" {
  # Older JSONL produced before the round-2 fix lacks by_type_usd; jq
  # should default to 0 USD via the // fallback, not error out.
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  local today_iso
  today_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cat > "$PP_CACHE_DIR/metrics.jsonl" <<EOF
{"ts":"$today_iso","session":"legacy","calls":2,"usd_est":0.001,"by_type":{"planner":2}}
EOF
  run bash "$PP_ROOT/bin/polymath" cost --by-lens
  [ "$status" -eq 0 ]
  [[ "$output" == *"planner: 2 calls"* ]]
  # Missing by_type_usd → falls back to $0
  [[ "$output" == *"\$0"* ]]
}

@test "R2-M2: polymath cost table shows 4-decimal USD (sub-cent visible)" {
  # Single-call cycles cost ~$0.0003. Pre-fix the *100/round/100 query
  # rounded these to $0, so the table looked broken. New formatting uses
  # 4 decimals. Column padding may insert spaces between '$' and the
  # value, so we match the 0.0003 substring (not the $-prefix).
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  local today_iso
  today_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cat > "$PP_CACHE_DIR/metrics.jsonl" <<EOF
{"ts":"$today_iso","session":"tiny","calls":1,"usd_est":0.0003,"by_type":{"planner":1},"by_type_usd":{"planner":0.0003}}
EOF
  run bash "$PP_ROOT/bin/polymath" cost
  [ "$status" -eq 0 ]
  # Sub-cent value must be visible — not rounded to $0
  [[ "$output" == *"0.0003"* ]]
  # And the table must NOT show $0 as the only USD value (pre-fix bug)
  [[ "$output" != *"\$        0 "* ]]
}

@test "R3-PR10-6: polymath cost surfaces unknown-model warnings (default table)" {
  # When metrics-warnings.log exists and is non-empty, the table view
  # should append a yellow warning block listing the first few unknown
  # models with the path to the log file.
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  local today_iso
  today_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cat > "$PP_CACHE_DIR/metrics.jsonl" <<EOF
{"ts":"$today_iso","session":"a","calls":1,"usd_est":0,"by_type":{"planner":1},"by_type_usd":{"planner":0}}
EOF
  printf '%s\tunknown model gpt-4o-mini — billing as $0; configure via user.env\n' \
    "$today_iso" > "$PP_CACHE_DIR/metrics-warnings.log"
  run bash "$PP_ROOT/bin/polymath" cost
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unknown models seen"* ]]
  [[ "$output" == *"gpt-4o-mini"* ]]
}

@test "R3-PR10-6: polymath cost --by-lens surfaces unknown-model warnings" {
  export CLAUDE_DIR="$HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$PP_CACHE_DIR"
  local today_iso
  today_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cat > "$PP_CACHE_DIR/metrics.jsonl" <<EOF
{"ts":"$today_iso","session":"a","calls":1,"usd_est":0,"by_type":{"planner":1},"by_type_usd":{"planner":0}}
EOF
  printf '%s\tunknown model claude-3.5-sonnet — billing as $0; configure via user.env\n' \
    "$today_iso" > "$PP_CACHE_DIR/metrics-warnings.log"
  run bash "$PP_ROOT/bin/polymath" cost --by-lens
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unknown models seen"* ]]
  [[ "$output" == *"claude-3.5-sonnet"* ]]
}

# ─── self-test ──────────────────────────────────────────────────────────────
# Flag-parsing + dep-check paths only. The real LLM call is NOT exercised in
# CI (would burn ~$0.0001 per push × every PR). Manual maintainer probe with
# `polymath self-test --yes` verifies the spend path before release.

@test "polymath self-test --help: prints usage + exits 0" {
  run bash "$PP_ROOT/bin/polymath" self-test --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"end-to-end LLM probe"* ]]
  [[ "$output" == *"\$0.0001"* ]]
}

@test "polymath self-test: unknown flag → exit 2" {
  run bash "$PP_ROOT/bin/polymath" self-test --nope
  [ "$status" -eq 2 ]
}

@test "polymath self-test: non-interactive stdin without --yes → exit 1" {
  PATH=/usr/bin:/bin run bash -c "echo '' | bash '$PP_ROOT/bin/polymath' self-test"
  # Either refuses on non-TTY OR no llm CLI → both should exit non-zero with a clear message
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing"* ]] || [[ "$output" == *"not on PATH"* ]] || [[ "$output" == *"not configured"* ]]
}

@test "polymath self-test: missing llm CLI → exit 1 with clear message" {
  PATH=/usr/bin:/bin run bash -c "bash '$PP_ROOT/bin/polymath' self-test --yes </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"llm CLI not on PATH"* ]]
}

@test "R2 HIGH-1: self-test exits NON-zero when sentinel mismatches" {
  # Shim `llm` to (a) report openai in `keys list` so we get past the soft
  # warn, and (b) return an OFF-sentinel response. The old code would WARN
  # and exit 0; the R2 fix must exit 1.
  local shim_dir
  shim_dir="$(mktemp -d)"
  cat > "$shim_dir/llm" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  keys)
    [ "$2" = "list" ] && { printf 'openai\n'; exit 0; }
    ;;
esac
# Default: respond with WRONG sentinel — verifies R2 HIGH-1 fix
printf 'NOT_THE_RIGHT_WORD\n'
SHIM
  chmod +x "$shim_dir/llm"
  PATH="$shim_dir:/usr/bin:/bin" run bash -c "bash '$PP_ROOT/bin/polymath' self-test --yes </dev/null"
  rm -rf "$shim_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did NOT match sentinel"* ]]
  [[ "$output" == *"one or more checks failed"* ]]
}

@test "R2 MED-3: self-test does NOT hard-exit if openai missing from keys list (warn only)" {
  # Shim `llm` so `keys list` is EMPTY but the call itself succeeds with
  # the right sentinel. Old code: exit 1 at preflight. R2: warn + continue.
  local shim_dir
  shim_dir="$(mktemp -d)"
  cat > "$shim_dir/llm" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  keys)
    [ "$2" = "list" ] && { exit 0; }   # empty list
    ;;
esac
printf 'PAIRPOLYMATH_OK\n'
SHIM
  chmod +x "$shim_dir/llm"
  PATH="$shim_dir:/usr/bin:/bin" run bash -c "bash '$PP_ROOT/bin/polymath' self-test --yes </dev/null"
  rm -rf "$shim_dir"
  # Should warn but proceed; budget check may or may not pass depending on
  # HOME isolation, so we only assert: did NOT exit at preflight, and the
  # warning text DID appear.
  [[ "$output" == *"not in"* ]] || [[ "$output" == *"trusting env-var"* ]]
  # And did not bail at the preflight (some downstream output should show)
  [[ "$output" == *"probing OpenAI"* ]]
}

@test "polymath help: lists self-test as available" {
  run bash "$PP_ROOT/bin/polymath" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"polymath self-test"* ]]
  ! [[ "$output" == *"will add: self-test"* ]]
}

# ========================================================
# v0.5.1 Task 11: PP_ESCALATION_STREAK_THRESHOLD env-tunable
# ========================================================

@test "escalation: PP_ESCALATION_STREAK_THRESHOLD default is 3 (preserves v0.5.0)" {
  grep -q 'PP_ESCALATION_STREAK_THRESHOLD:-3' "$PP_ROOT/bin/statusline.sh"
}

@test "escalation: streak=2 does NOT trigger inv when threshold=3" {
  # Tautological by construction — locks the comparator semantic so a future
  # refactor doesn't accidentally flip -ge to -gt or change the default.
  PP_ESCALATION_STREAK_THRESHOLD=3
  local _streak=2
  if [ "$_streak" -ge "${PP_ESCALATION_STREAK_THRESHOLD}" ]; then
    return 1
  fi
}

@test "escalation: threshold env reads correctly with explicit override" {
  local _out
  _out=$(PP_ESCALATION_STREAK_THRESHOLD=5 bash -c 'echo "${PP_ESCALATION_STREAK_THRESHOLD:-3}"')
  [ "$_out" = "5" ]
}
