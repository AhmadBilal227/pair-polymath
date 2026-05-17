#!/usr/bin/env bats
# v0.5.1.1 Stage D production wiring tests.
#
# The eligibility primitives can pass while production remains inert if
# bin/statusline.sh does not write/pass the cycle facts snapshot. This file
# pins the real statusline -> router boundary with a zero-cost fake llm.

setup() {
  command -v git >/dev/null 2>&1 || skip "git required"

  HOME="$(mktemp -d)"
  export HOME
  CLAUDE_DIR="$HOME/.claude"
  PP_CACHE_DIR="$CLAUDE_DIR/cache"
  PP_STATE_DIR="$CLAUDE_DIR/pair-polymath"
  mkdir -p "$PP_CACHE_DIR" "$PP_STATE_DIR/config"
  export CLAUDE_DIR PP_CACHE_DIR PP_STATE_DIR

  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT

  PP_REPO="$HOME/repo"
  mkdir -p "$PP_REPO/bin" "$PP_REPO/lib"
  git -C "$PP_REPO" init -q
  git -C "$PP_REPO" config user.email "test@example.com"
  git -C "$PP_REPO" config user.name "Pair Polymath Test"
  printf '#!/usr/bin/env bash\nprintf ok\n' > "$PP_REPO/bin/statusline.sh"
  printf '#!/usr/bin/env bash\nprintf router\n' > "$PP_REPO/lib/router.sh"
  git -C "$PP_REPO" add .
  git -C "$PP_REPO" commit -q -m "init"
  printf '\n# changed\n' >> "$PP_REPO/bin/statusline.sh"

  PP_TX="$HOME/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"work on bash lens gates"}}' > "$PP_TX"
  PP_STDIN="$HOME/stdin.json"
  printf '{"session_id":"lens-gate-wire","workspace":{"current_dir":"%s"},"model":{"display_name":"S"},"transcript_path":"%s","cost":{"total_cost_usd":0.0}}\n' \
    "$PP_REPO" "$PP_TX" > "$PP_STDIN"

  PP_FAKEBIN="$HOME/fakebin"
  mkdir -p "$PP_FAKEBIN"
  printf '#!/bin/sh\nprintf "SILENT\\n"\n' > "$PP_FAKEBIN/llm"
  chmod +x "$PP_FAKEBIN/llm"
  PATH="$PP_FAKEBIN:$PATH"
  export PATH PP_REPO PP_TX PP_STDIN
}

teardown() {
  rm -rf "$HOME"
}

@test "statusline passes facts snapshot into router lens-gates path" {
  cat > "$PP_STATE_DIR/config/user.env" <<EOF
PP_ROUTER_ENABLE=1
PP_ROUTER_SURPRISE_PROB=0
PP_LENS_GATES_ACTIVE=1
PP_LENS_GATES_TELEMETRY=1
PP_LENS_GATES_SHADOW_FILE="$PP_CACHE_DIR/lens-gates-shadow.jsonl"
PP_ROUTER_FORCE_OUTPUT="UX_DESIGN
ENGINEERING
SECURITY"
EOF

  bash "$PP_ROOT/bin/statusline.sh" < "$PP_STDIN" >/dev/null 2>&1 || true

  facts="$PP_CACHE_DIR/cc-monitor-facts-lens-gate-wire.txt"
  for _i in $(seq 1 50); do
    [ -f "$facts" ] && break
    sleep 0.1
  done
  [ -f "$facts" ]
  head -1 "$facts" | grep -qF '# facts_schema: 2'
  grep -qF '# git_diff_paths' "$facts"
  grep -qF 'bin/statusline.sh' "$facts"
  grep -qF '# git_untracked_paths' "$facts"
  grep -qF '# git_staged_paths' "$facts"

  shadow="$PP_CACHE_DIR/lens-gates-shadow.jsonl"
  for _i in $(seq 1 50); do
    [ -f "$shadow" ] && grep -qF '"lens_id":"SECURITY"' "$shadow" && break
    sleep 0.1
  done
  [ -f "$shadow" ]
  grep -F '"lens_id":"UX_DESIGN"' "$shadow" | grep -qF '"would_be_ineligible":1'
  grep -F '"lens_id":"ENGINEERING"' "$shadow" | grep -qF '"would_be_ineligible":0'
  grep -F '"lens_id":"SECURITY"' "$shadow" | grep -qF '"would_be_ineligible":0'
}
