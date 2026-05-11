#!/usr/bin/env bash
# Pair Polymath installer — minimal lean v1.
# Detects deps, installs if missing (interactive), prompts for OpenAI key,
# merges into ~/.claude/settings.json with backup. Idempotent.
#
# Usage: ./install.sh
# v0.2 will add --dry-run, --no-sudo, --yes flags + audit log + doctor check.

set -e
set -u

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

if command -v brew >/dev/null 2>&1; then
  PKG_INSTALL_JQ="brew install jq"
elif command -v apt-get >/dev/null 2>&1; then
  # apt-get update is mandatory: GitHub Actions runners (and many fresh
  # container images) ship with stale package indexes that reference
  # versions no longer present on mirrors. Without update, the install
  # 404s on the cached version.
  PKG_INSTALL_JQ="sudo apt-get update && sudo apt-get install -y jq"
else
  err "Could not find brew or apt-get — install jq manually then re-run."
  exit 1
fi

PIP_INSTALL_LLM="pip3 install --user 'llm>=0.20,<1.0'"

check_or_install jq "$PKG_INSTALL_JQ"
check_or_install llm "$PIP_INSTALL_LLM"

# pip --user installs to ~/.local/bin (Linux) or ~/Library/Python/.../bin (macOS),
# which may not be on PATH. Verify llm is now invocable; print PATH hint if not.
if ! command -v llm >/dev/null 2>&1; then
  warn "'llm' was installed but is not on PATH."
  warn "Add this to your shell rc (\$HOME/.bashrc / .zshrc) and restart the shell:"
  printf '    export PATH="$HOME/.local/bin:$PATH"\n'
  warn "Then re-run this installer."
  exit 1
fi

# === Step 3: OpenAI key ===
step "OpenAI API key"
if llm keys list 2>/dev/null | grep -q '^openai$'; then
  ok "openai key already configured in llm CLI"
else
  printf '  Pair Polymath uses gpt-5 family models.\n'
  printf '  Get a key: https://platform.openai.com/api-keys\n'
  prompt "Paste your OpenAI key (sk-...) or press Enter to skip:"
  # No-echo for the secret. `|| true` keeps set -e happy when stdin isn't a tty.
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

# === Step 5: Smoke-test BEFORE touching settings.json (review fix H3) ===
# If statusline.sh is broken in this checkout, fail before pointing settings
# at it. Otherwise we'd leave the user with a broken statusLine.
step "Smoke-testing statusline before activating"
if [ -f "$PP_ROOT/test/fixtures/stdin-sample.json" ]; then
  if cat "$PP_ROOT/test/fixtures/stdin-sample.json" | bash "$PP_ROOT/bin/statusline.sh" >/dev/null 2>&1; then
    ok "statusline.sh exits 0 on sample input"
  else
    err "statusline.sh failed smoke test — aborting; settings.json untouched."
    exit 1
  fi
else
  warn "no smoke fixture found; skipping pre-flight test"
fi

# === Step 6: Merge into settings.json ===
step "Merging into $SETTINGS_FILE"

# Quote paths so the shell command string in settings.json survives word-splitting
# when PP_ROOT contains spaces (review fix M2). Single-quoted around the path
# means bash strips the quotes and runs the path as one argument.
SL_CMD="bash '${PP_ROOT}/bin/statusline.sh'"
HOOK_USER_CMD="'${PP_ROOT}/hooks/inject-monitor-insight.sh'"
HOOK_POST_CMD="'${PP_ROOT}/hooks/cache-test-result.sh'"

if [ -f "$SETTINGS_FILE" ]; then
  bak="${SETTINGS_FILE}.bak.$(date +%s)"
  cp "$SETTINGS_FILE" "$bak"
  ok "backup: $bak"

  # Review fix H1: if a different statusLine is already set, prompt before clobber.
  existing_sl=$(jq -r '.statusLine?.command // ""' "$SETTINGS_FILE" 2>/dev/null)
  install_statusline=1
  if [ -n "$existing_sl" ] && [ "$existing_sl" != "$SL_CMD" ]; then
    warn "Existing statusLine detected:"
    printf '    %s\n' "$existing_sl"
    prompt "Replace with Pair Polymath statusLine? [y/N]"
    read -r ans
    case "${ans:-N}" in
      [Yy]*) install_statusline=1 ;;
      *)     install_statusline=0; warn "Keeping existing statusLine; installing hooks only." ;;
    esac
  fi
else
  echo '{}' > "$SETTINGS_FILE"
  install_statusline=1
fi

# Create tmp in the SAME directory as settings.json so the eventual mv stays
# atomic-rename-within-filesystem. Bare `mktemp` lands in /tmp (often tmpfs on
# Linux) which makes mv a non-atomic copy+delete with a race window — Claude
# Code reads settings.json on every prompt, so a partial read is a real risk.
# Caught by the ENGINEERING lens on 2026-05-11.
tmp=$(mktemp "${SETTINGS_FILE}.XXXXXX") || { err "mktemp failed"; exit 1; }
jq --arg sl "$SL_CMD" \
   --arg hook_user "$HOOK_USER_CMD" \
   --arg hook_post "$HOOK_POST_CMD" \
   --argjson set_sl "$install_statusline" '
  # statusLine (conditional on $set_sl)
  (if $set_sl == 1 then .statusLine = {type: "command", command: $sl, refreshInterval: 2} else . end)
  |
  # UserPromptSubmit hook — append if not already present (idempotent)
  (.hooks //= {})
  | (.hooks.UserPromptSubmit //= [])
  | (.hooks.UserPromptSubmit |= (
      if any(.[]; .hooks[]?.command == $hook_user) then .
      else . + [{matcher: "*", hooks: [{type: "command", command: $hook_user, timeout: 3}]}]
      end))
  |
  # PostToolUse hook — append if not already present (idempotent)
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
if [ "$install_statusline" = "1" ]; then
  ok "settings.json updated (statusLine + 2 hooks)"
else
  ok "settings.json updated (2 hooks; existing statusLine preserved)"
fi

# === Done ===
printf '\n\033[1m\033[32m✓ Pair Polymath installed.\033[0m\n'
printf '\n  Next: open a new Claude Code session.\n'
printf '  The first lens cycle completes within ~5 min of activity.\n'
printf '\n  Status check: \033[1mbash %s/bin/polymath status\033[0m\n' "$PP_ROOT"
printf '  Override config: edit \033[1m%s/config/user.env\033[0m\n' "$USER_CONFIG_DIR"
printf '  Custom lens: drop JSON into \033[1m%s/lenses/\033[0m\n' "$USER_CONFIG_DIR"
printf '  Custom prompt: drop .md into \033[1m%s/prompts/\033[0m\n' "$USER_CONFIG_DIR"
