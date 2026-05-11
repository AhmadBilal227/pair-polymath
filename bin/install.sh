#!/usr/bin/env bash
# Pair Polymath installer — minimal lean v1.
# Detects deps, installs if missing (interactive), prompts for OpenAI key,
# merges into ~/.claude/settings.json with backup. Idempotent.
#
# Usage: ./install.sh
# v0.2 will add --dry-run, --no-sudo, --yes flags + audit log + doctor check.

set -e
set -u

# Locate plugin root (the dir containing bin/, lib/, etc.)
PP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
USER_CONFIG_DIR="$CLAUDE_DIR/pair-polymath"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; }
prompt() { printf '  \033[36m?\033[0m %s ' "$1"; }

# === Step 1: Greeting + sanity ===
step "Pair Polymath installer (v$(cat "$PP_ROOT/VERSION"))"
printf '  Plugin root: %s\n' "$PP_ROOT"
printf '  Claude dir:  %s\n' "$CLAUDE_DIR"

if [ ! -d "$CLAUDE_DIR" ]; then
  warn "Claude Code dir not found at $CLAUDE_DIR"
  prompt "Create it? [Y/n]"
  read -r ans
  case "${ans:-Y}" in
    [Yy]*|"") mkdir -p "$CLAUDE_DIR" ;;
    *) err "Aborting — no Claude Code dir."; exit 1 ;;
  esac
fi

# === Step 2: Detect/install deps ===
step "Checking dependencies"

check_or_install() {
  local cmd="$1"
  local install_cmd="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd: $(command -v "$cmd")"
    return 0
  fi
  warn "$cmd not found"
  prompt "Install via '$install_cmd'? [Y/n]"
  read -r ans
  case "${ans:-Y}" in
    [Yy]*|"") eval "$install_cmd" && ok "$cmd installed" || { err "install failed"; return 1; } ;;
    *) err "$cmd is required — aborting"; return 1 ;;
  esac
}

# Detect package manager
if command -v brew >/dev/null 2>&1; then
  PKG_INSTALL_JQ="brew install jq"
elif command -v apt-get >/dev/null 2>&1; then
  PKG_INSTALL_JQ="sudo apt-get install -y jq"
else
  err "Could not find brew or apt-get — install jq manually then re-run."
  exit 1
fi

# Use pip3 for llm (Python). Pinned for supply-chain safety.
PIP_INSTALL_LLM="pip3 install --user 'llm>=0.20,<1.0'"

check_or_install jq "$PKG_INSTALL_JQ"
check_or_install llm "$PIP_INSTALL_LLM"

# === Step 3: OpenAI key ===
step "OpenAI API key"
if llm keys list 2>/dev/null | grep -q '^openai$'; then
  ok "openai key already configured in llm CLI"
else
  printf '  Pair Polymath uses gpt-5 family models.\n'
  printf '  Get a key: https://platform.openai.com/api-keys\n'
  prompt "Paste your OpenAI key (sk-...) or press Enter to skip:"
  # Read with no-echo for the secret. `|| true` so a non-tty stdin (CI/heredoc)
  # doesn't trip set -e — we still read, just without the echo guard.
  stty -echo 2>/dev/null || true
  read -r openai_key || openai_key=""
  stty echo 2>/dev/null || true
  printf '\n'
  if [ -n "$openai_key" ]; then
    printf '%s\n' "$openai_key" | llm keys set openai
    ok "openai key stored"
  else
    warn "Skipping key setup. Configure later: llm keys set openai"
  fi
fi

# === Step 4: User config dir ===
step "Setting up user override directory"
mkdir -p "$USER_CONFIG_DIR"/{lenses,prompts,cache,config}
chmod 700 "$USER_CONFIG_DIR" 2>/dev/null || true
if [ ! -f "$USER_CONFIG_DIR/config/user.env" ]; then
  cat > "$USER_CONFIG_DIR/config/user.env" <<'EOF'
# Pair Polymath user overrides — copy any defaults you want to change here.
# All variables and their defaults live in $PP_ROOT/config/default.env.
#
# Example overrides:
# PP_MAX_DAILY_CALLS=2000     # lower the daily LLM-call cap (default 3500)
# PP_EXTERNAL_LLM=0           # disable LLM cycle entirely (status-only mode)
# PP_ENABLE_ESCALATION=0      # disable deep-investigation escalation
EOF
  ok "wrote $USER_CONFIG_DIR/config/user.env (commented defaults)"
else
  ok "$USER_CONFIG_DIR/config/user.env already exists — preserved"
fi

# === Step 5: Merge into settings.json ===
step "Merging into $SETTINGS_FILE"
if [ -f "$SETTINGS_FILE" ]; then
  bak="${SETTINGS_FILE}.bak.$(date +%s)"
  cp "$SETTINGS_FILE" "$bak"
  ok "backup: $bak"
else
  echo '{}' > "$SETTINGS_FILE"
fi

# Use jq to atomically merge our entries. Idempotent: re-running won't double-add.
tmp=$(mktemp)
jq --arg sl "bash $PP_ROOT/bin/statusline.sh" \
   --arg hook_user "$PP_ROOT/hooks/inject-monitor-insight.sh" \
   --arg hook_post "$PP_ROOT/hooks/cache-test-result.sh" '
  # statusLine
  .statusLine = {type: "command", command: $sl, refreshInterval: 2}
  |
  # UserPromptSubmit hook
  (.hooks.UserPromptSubmit //= [])
  | (.hooks.UserPromptSubmit |= (
      if any(.[]; .hooks[]?.command == $hook_user) then .
      else . + [{matcher: "*", hooks: [{type: "command", command: $hook_user, timeout: 3}]}]
      end))
  |
  # PostToolUse hook
  (.hooks.PostToolUse //= [])
  | (.hooks.PostToolUse |= (
      if any(.[]; .hooks[]?.command == $hook_post) then .
      else . + [{matcher: "Bash", hooks: [{type: "command", command: $hook_post, timeout: 3}]}]
      end))
' "$SETTINGS_FILE" > "$tmp"

if ! jq empty "$tmp" 2>/dev/null; then
  err "Merged settings.json is invalid JSON — aborting (original preserved)."
  rm -f "$tmp"
  exit 1
fi

mv "$tmp" "$SETTINGS_FILE"
ok "settings.json updated (statusLine + 2 hooks)"

# === Step 6: Smoke test ===
step "Smoke-testing statusline"
if [ -f "$PP_ROOT/test/fixtures/stdin-sample.json" ]; then
  if cat "$PP_ROOT/test/fixtures/stdin-sample.json" | bash "$PP_ROOT/bin/statusline.sh" >/dev/null 2>&1; then
    ok "statusline.sh exits 0 on sample input"
  else
    err "statusline.sh failed smoke test — installation aborted before activating"
    exit 1
  fi
fi

# === Done ===
printf '\n\033[1m\033[32m✓ Pair Polymath installed.\033[0m\n'
printf '\n  Next: open a new Claude Code session.\n'
printf '  The first lens cycle completes within ~5 min of activity.\n'
printf '\n  Status check: \033[1mbash %s/bin/polymath status\033[0m\n' "$PP_ROOT"
printf '  Override config: edit \033[1m%s/config/user.env\033[0m\n' "$USER_CONFIG_DIR"
printf '  Custom lens: drop JSON into \033[1m%s/lenses/\033[0m\n' "$USER_CONFIG_DIR"
printf '  Custom prompt: drop .md into \033[1m%s/prompts/\033[0m\n' "$USER_CONFIG_DIR"
