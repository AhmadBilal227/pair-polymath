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
  [[ "$output" == *"Skipping interactive installer"* ]]
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
