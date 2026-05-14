#!/usr/bin/env bash
# Pair Polymath installer — v0.2 (P2.3 flags + audit log + bare-install detection).
# Detects deps, installs if missing (interactive), prompts for OpenAI key,
# merges into ~/.claude/settings.json with backup. Idempotent.
#
# Usage: ./install.sh [--dry-run] [--yes] [--no-sudo] [--non-interactive] [--help]
# Run with --help for full flag reference.

set -e
set -u

# === Flag parsing (P2.3) ===
PP_DRY_RUN=0
PP_YES=0
PP_NO_SUDO=0
PP_VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) PP_DRY_RUN=1 ;;
    --yes|-y) PP_YES=1 ;;
    --no-sudo) PP_NO_SUDO=1 ;;
    --verbose|-v) PP_VERBOSE=1 ;;
    --non-interactive) PP_YES=1; PP_NO_SUDO=1 ;;
    -h|--help)
      cat <<'HELP'
bin/install.sh — Pair Polymath installer

Usage:
  ./bin/install.sh [flags]

Flags:
  --dry-run             Print every action with [DRY-RUN] prefix.
                        Make NO filesystem changes. Useful for CI / paranoid users.
  --yes, -y             Skip all interactive prompts. Take defaults:
                        - jq/llm install: yes
                        - existing statusLine conflict: keep theirs
                        - OpenAI key prompt: skip (configure later with llm keys set openai)
  --no-sudo             Refuse to invoke sudo. Useful for unprivileged or
                        rootless environments. If a dep install needs sudo,
                        print the exact command + exit 1.
  --non-interactive     Alias for --yes --no-sudo. Useful for CI.
  --verbose, -v         Stream dep-install output (pip3, brew, apt) directly to
                        the terminal instead of capturing to the audit log. Use
                        this when a step is failing and you need to SEE why.
  --help, -h            This message.

Audit log:
  $CLAUDE_DIR/pair-polymath/install.log  (JSONL, one line per significant
  action; NOT written under --dry-run since dry-run makes no FS changes)

Exit codes:
  0   Success (real install or --dry-run completed)
  1   Setup failure (missing deps after attempts, smoke-test failed, sudo
      refused under --no-sudo, etc.)
  2   Bad flag / usage
HELP
      exit 0
      ;;
    *)
      printf 'install.sh: unknown flag %s. Try --help.\n' "$arg" >&2
      exit 2
      ;;
  esac
done

PP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
USER_CONFIG_DIR="$CLAUDE_DIR/pair-polymath"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

# shellcheck disable=SC1091
. "$PP_ROOT/lib/audit-log.sh"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; }
prompt() {
  printf '  \033[36m?\033[0m %s ' "$1"
  if [ "$PP_YES" = "1" ]; then
    printf '[--yes auto-accepting default]\n'
  fi
}

# Read an answer from stdin OR auto-default under --yes.
# Sets the global $ans variable.
ans=""
read_ans() {
  if [ "$PP_YES" = "1" ]; then
    ans=""  # empty triggers default branch in case statements
  else
    read -r ans || ans=""
  fi
}

# _pp_run ACTION COMMAND...
# Runs COMMAND, logs to audit log, respects --dry-run.
# In dry-run mode, prints [DRY-RUN] + command, returns 0.
# Otherwise runs the command, captures stderr tail, logs, returns the command's exit code.
_pp_run() {
  local action="$1"
  shift
  local cmd_str="$*"

  if [ "$PP_DRY_RUN" = "1" ]; then
    printf '  [DRY-RUN] %s\n' "$cmd_str"
    audit_log "$action" "$cmd_str" 0 "dry-run"
    return 0
  fi

  # R3 fix (R2's tee >&2 had a process-substitution race: bash doesn't wait
  # on the proc-sub child before continuing, so `tail -c 500` could read
  # before tee finished flushing → empty audit log under --verbose, exactly
  # the regression R2 claimed to fix). Simpler + race-free: always capture
  # stderr to a file, then if --verbose, cat the file to stderr AFTER the
  # command completes. Trades real-time streaming for reliability — most
  # installer steps finish in <30s and "see why it failed" is the use case.
  local stderr_tmp
  stderr_tmp=$(mktemp 2>/dev/null) || stderr_tmp="/tmp/pp-stderr-$$"
  local rc=0
  "$@" 2> "$stderr_tmp" || rc=$?
  if [ "$PP_VERBOSE" = "1" ] && [ -s "$stderr_tmp" ]; then
    cat "$stderr_tmp" >&2
  fi
  local stderr_tail=""
  if [ -s "$stderr_tmp" ]; then
    stderr_tail=$(tail -c 500 "$stderr_tmp")
  fi
  # CRITICAL UX FIX: on failure, SHOW the captured stderr to the user.
  # Previously stderr went to a tmp file → audit log only, and the user saw
  # only "install failed" with no diagnostic. That's how a real install on
  # a fresh device hit "pip3 install --user llm" failing under PEP 668 with
  # zero actionable feedback (the install log is at $CLAUDE_DIR/pair-polymath/
  # install.log but most users don't know to look there).
  if [ "$rc" -ne 0 ] && [ -n "$stderr_tail" ]; then
    printf '\n  \033[2m--- stderr (last 500 bytes) ---\033[0m\n' >&2
    printf '%s\n' "$stderr_tail" >&2
    printf '  \033[2m--- end stderr ---\033[0m\n' >&2
    printf '  \033[2mFull audit log: %s\033[0m\n' "$PP_AUDIT_LOG" >&2
    printf '  \033[2mTip: re-run with --verbose to see live install output.\033[0m\n' >&2
  fi
  rm -f "$stderr_tmp"
  audit_log "$action" "$cmd_str" "$rc" "$stderr_tail"
  return "$rc"
}

# _pp_eval ACTION COMMAND_STRING
# Same as _pp_run but evaluates a single command-string (for shell pipelines / && chains).
_pp_eval() {
  local action="$1"
  local cmd_str="$2"

  if [ "$PP_DRY_RUN" = "1" ]; then
    printf '  [DRY-RUN] %s\n' "$cmd_str"
    audit_log "$action" "$cmd_str" 0 "dry-run"
    return 0
  fi

  # R3 fix: same race-free pattern as _pp_run — capture to file, then if
  # --verbose, cat to stderr after the command completes. No process
  # substitution, no wait gymnastics, no truncated audit log.
  local stderr_tmp
  stderr_tmp=$(mktemp 2>/dev/null) || stderr_tmp="/tmp/pp-stderr-$$"
  local rc=0
  eval "$cmd_str" 2> "$stderr_tmp" || rc=$?
  if [ "$PP_VERBOSE" = "1" ] && [ -s "$stderr_tmp" ]; then
    cat "$stderr_tmp" >&2
  fi
  local stderr_tail=""
  if [ -s "$stderr_tmp" ]; then
    stderr_tail=$(tail -c 500 "$stderr_tmp")
  fi
  # Same UX fix as _pp_run — surface stderr on failure
  if [ "$rc" -ne 0 ] && [ -n "$stderr_tail" ]; then
    printf '\n  \033[2m--- stderr (last 500 bytes) ---\033[0m\n' >&2
    printf '%s\n' "$stderr_tail" >&2
    printf '  \033[2m--- end stderr ---\033[0m\n' >&2
    printf '  \033[2mFull audit log: %s\033[0m\n' "$PP_AUDIT_LOG" >&2
    printf '  \033[2mTip: re-run with --verbose to see live install output.\033[0m\n' >&2
  fi
  rm -f "$stderr_tmp"
  audit_log "$action" "$cmd_str" "$rc" "$stderr_tail"
  return "$rc"
}

# === Step 1: Greeting + sanity ===
step "Pair Polymath installer (v$(cat "$PP_ROOT/VERSION"))"
printf '  Plugin root: %s\n' "$PP_ROOT"
printf '  Claude dir:  %s\n' "$CLAUDE_DIR"
if [ "$PP_DRY_RUN" = "1" ]; then
  printf '  Mode:        \033[1mDRY-RUN\033[0m (no filesystem changes)\n'
fi
if [ "$PP_YES" = "1" ]; then
  printf '  Prompts:     auto-accepting defaults (--yes)\n'
fi
if [ "$PP_NO_SUDO" = "1" ]; then
  printf '  Sudo:        refused (--no-sudo)\n'
fi

# === Bare-install detection (P2.3) — DETECTION ONLY, read-only ===
# Review fix HIGH-1: detect the bare-install marker BEFORE the consent
# prompt (read-only, no FS writes). The counter bump and audit-log entry
# are deferred until AFTER consent so a declining user leaves $CLAUDE_DIR
# absent and we write nothing to disk.
BARE_STATUSLINE="$CLAUDE_DIR/statusline-command.sh"
MIGRATION_COUNTER="$CLAUDE_DIR/pair-polymath/cache/migration-requests.txt"
PP_BARE_INSTALL_DETECTED=0
if [ -f "$BARE_STATUSLINE" ]; then
  PP_BARE_INSTALL_DETECTED=1
  warn "Detected existing bare-install setup at $BARE_STATUSLINE"
  cat <<MIGRATE

  Pair Polymath is a plugin that supersedes this bare-install pattern.
  Recommended manual migration:

    1. Back up your current Claude Code config:
         cp ~/.claude/settings.json ~/.claude/settings.json.pre-pp-bak
    2. (Optional) Move the old statusline aside:
         mv ~/.claude/statusline-command.sh ~/.claude/statusline-command.sh.pre-pp
    3. Continue this installer — it will prompt before replacing your
       statusLine in settings.json (default: keep yours).

  We do NOT auto-migrate. v0.3 may add bin/migrate-from-bare.sh if demand
  warrants (currently tracked: this installer bumps a counter at
  $MIGRATION_COUNTER and the v0.3 trigger is >=3 hits / 14 days).
MIGRATE
fi

# === Claude-dir consent prompt (review fix HIGH-1) ===
# Previously audit_log("install-start") ran above this block, and audit_log's
# mkdir -p "$CLAUDE_DIR/pair-polymath/" silently created $CLAUDE_DIR itself —
# making this prompt a lie. Now: no FS writes happen before this point. If
# the user declines we exit 0 (their choice, not a failure) and write
# nothing to disk.
if [ ! -d "$CLAUDE_DIR" ]; then
  warn "Claude Code dir not found at $CLAUDE_DIR"
  prompt "Create it? [Y/n]"
  read_ans
  case "${ans:-Y}" in
    [Yy]*|"")
      if [ "$PP_DRY_RUN" = "1" ]; then
        printf '  [DRY-RUN] mkdir -p %s\n' "$CLAUDE_DIR"
        # Audit log not written under --dry-run; nothing to log here either.
      else
        # Direct mkdir (not _pp_run, since audit-log machinery isn't yet active
        # — we cannot write a log entry that lives inside the dir we're about
        # to create until AFTER it exists).
        mkdir -p "$CLAUDE_DIR" || {
          err "Could not create $CLAUDE_DIR"
          exit 1
        }
      fi
      ;;
    *)
      # User declined — friendly abort. No audit log (no $CLAUDE_DIR to
      # write it to by user choice). Exit 0: declining is a valid choice,
      # not a setup failure.
      printf '  Aborting — no Claude Code dir created (user choice).\n'
      printf '  To install later: re-run this script and accept the prompt.\n'
      exit 0
      ;;
  esac
fi

# === NOW that $CLAUDE_DIR exists (or dry-run is in effect), emit the first audit log entry ===
# audit_log() is a no-op under --dry-run, so this is also safe in dry-run mode.
audit_log "install-start" "bin/install.sh $*" 0 ""

# === Bare-install counter bump (review fix HIGH-1, MEDIUM-5) ===
# Now that consent is confirmed and $CLAUDE_DIR exists, bump the counter.
if [ "$PP_BARE_INSTALL_DETECTED" = "1" ]; then
  if [ "$PP_DRY_RUN" = "1" ]; then
    printf '  [DRY-RUN] Would bump migration-requests counter at %s\n' "$MIGRATION_COUNTER"
    # No audit-log entry under --dry-run (HIGH-3 / contract).
  else
    counter_dir="$(dirname "$MIGRATION_COUNTER")"
    mkdir -p "$counter_dir" 2>/dev/null || true
    _pp_count=0
    if [ -f "$MIGRATION_COUNTER" ]; then
      _pp_count=$(cat "$MIGRATION_COUNTER" 2>/dev/null || echo 0)
      # Guard against non-numeric contents.
      case "$_pp_count" in
        ''|*[!0-9]*) _pp_count=0 ;;
      esac
    fi
    # Review fix MEDIUM-5: atomic write via mktemp-in-same-dir + mv. Two
    # concurrent installers can still both read the same old value (TOCTOU
    # at the read step — would need flock to fully eliminate), but the WRITE
    # is atomic so we never half-write the file.
    counter_tmp=""
    if counter_tmp=$(mktemp "${MIGRATION_COUNTER}.XXXXXX" 2>/dev/null); then
      printf '%d\n' "$((_pp_count + 1))" > "$counter_tmp"
      if ! mv "$counter_tmp" "$MIGRATION_COUNTER" 2>/dev/null; then
        rm -f "$counter_tmp"
        warn "counter mv failed; counter not bumped"
      fi
    else
      warn "mktemp failed; counter not bumped"
    fi
    audit_log "bare-install-detected" "$BARE_STATUSLINE" 0 "counter bumped to $((_pp_count + 1))"
  fi

  if [ "$PP_YES" != "1" ]; then
    prompt "Migrate manually first? [y/N]"
    read_ans
    case "${ans:-N}" in
      [Yy]*)
        printf '  Aborting installer; come back after manual migration.\n'
        audit_log "abort" "user opted to migrate first" 0 ""
        exit 0
        ;;
    esac
  fi
fi

# === Step 2: Detect/install deps ===
step "Checking dependencies"

check_or_install() {
  local cmd="$1"
  local install_cmd="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd: $(command -v "$cmd")"
    audit_log "dep-check" "command -v $cmd" 0 "present"
    return 0
  fi
  warn "$cmd not found"

  # Review fix MEDIUM-1: empty install_cmd means we had no package manager to
  # build one with. Under --dry-run we treat this as informational; otherwise
  # the no-package-manager branch above would already have exited 1.
  if [ -z "$install_cmd" ]; then
    if [ "$PP_DRY_RUN" = "1" ]; then
      printf '  [DRY-RUN] Would require manual install of %s (no package manager detected).\n' "$cmd"
      return 0
    fi
    err "$cmd is required but no package manager is available — install it manually then re-run."
    audit_log "dep-install" "$cmd" 1 "no package manager"
    return 1
  fi

  # --no-sudo: refuse before prompting if the install command involves sudo
  # anywhere (leading or embedded after `&&`).
  if [ "$PP_NO_SUDO" = "1" ]; then
    case " $install_cmd " in
      *' sudo '*)
        err "$cmd needs sudo but --no-sudo is set. Run manually:"
        err "  $install_cmd"
        audit_log "dep-install" "$install_cmd" 1 "--no-sudo refused"
        return 1
        ;;
    esac
  fi

  prompt "Install via '$install_cmd'? [Y/n]"
  read_ans
  case "${ans:-Y}" in
    [Yy]*|"")
      if _pp_eval "dep-install" "$install_cmd"; then
        ok "$cmd installed"
      else
        err "install failed"
        return 1
      fi
      ;;
    *) err "$cmd is required — aborting"; audit_log "dep-install" "$install_cmd" 1 "user declined"; return 1 ;;
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
elif command -v jq >/dev/null 2>&1; then
  # No package manager but jq is already present. We won't need to install
  # anything; leave PKG_INSTALL_JQ unset (check_or_install will short-circuit
  # on the `command -v` check before consulting it).
  PKG_INSTALL_JQ=""
else
  # No package manager AND no jq.
  # Review fix MEDIUM-1: under --dry-run, this is informational, not fatal.
  # check_or_install treats empty install_cmd as "manual action required"
  # and prints a [DRY-RUN] line instead of exiting.
  if [ "$PP_DRY_RUN" = "1" ]; then
    warn "No package manager detected (brew/apt-get). Dry-run continues without dep-install plan."
    PKG_INSTALL_JQ=""
  else
    err "Could not find brew or apt-get — install jq manually then re-run."
    audit_log "dep-install" "jq" 1 "no package manager available"
    exit 1
  fi
fi

# === OS detection + LLM install strategy selection ===
# Detect the platform we're on so we pick the *native* install path instead
# of a guess-and-fallback chain. A real new-device install on Ubuntu 24.04
# failed silently here pre-fix: pip3 hit PEP 668's "externally-managed-
# environment" but the user only saw "install failed". OS-aware selection
# prefers pipx on PEP-668-locked Linux, brew+pipx on macOS, and pip3 elsewhere.
PP_OS="unknown"
PP_OS_VERSION=""
PP_OS_LIKE=""   # ID_LIKE — populated from /etc/os-release on Linux derivatives
case "$(uname -s 2>/dev/null)" in
  Darwin)
    PP_OS="macos"
    PP_OS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "?")
    ;;
  Linux)
    if [ -r /etc/os-release ]; then
      # /etc/os-release is the freedesktop.org standard. Sets $ID, $VERSION_ID,
      # $ID_LIKE. R2 fix: unset first (defense against parent-env leakage),
      # source under +e/+u (malformed file shouldn't abort the installer —
      # Code-reviewer H1), then re-enable strict mode.
      unset ID VERSION_ID ID_LIKE
      set +e +u
      # shellcheck disable=SC1091
      . /etc/os-release 2>/dev/null
      set -e -u
      PP_OS="${ID:-linux}"
      PP_OS_VERSION="${VERSION_ID:-?}"
      PP_OS_LIKE="${ID_LIKE:-}"
    else
      PP_OS="linux"
    fi
    ;;
esac

# PEP 668 detection: modern Debian/Ubuntu/Fedora and Homebrew Python drop a
# marker file in their stdlib that signals "do not pip3 install --user here."
# R2 fix: add /opt/homebrew/lib/python3*/ (Apple Silicon brew) and
# /usr/local/lib/python3*/ (Intel macOS brew) — the original glob missed
# both, so brew-Python-only users got incorrectly routed to pip3 --user.
PP_PEP668=0
for marker in \
    /usr/lib/python3*/EXTERNALLY-MANAGED \
    /usr/lib/python3/EXTERNALLY-MANAGED \
    /opt/homebrew/lib/python3*/EXTERNALLY-MANAGED \
    /usr/local/lib/python3*/EXTERNALLY-MANAGED \
    /Library/Frameworks/Python.framework/Versions/*/lib/python3.*/EXTERNALLY-MANAGED; do
  if [ -e "$marker" ]; then
    PP_PEP668=1
    break
  fi
done

# Print PEP 668 status only on Linux (where the install path actually depends
# on it). On macOS the brew-then-pipx path doesn't care — and showing
# "PEP 668" there is just confusing user-facing noise.
printf '  Detected: %s %s' "$PP_OS" "$PP_OS_VERSION"
if [ "$PP_OS" != "macos" ] && [ "$PP_PEP668" = "1" ]; then
  printf ' (PEP 668 — externally-managed-environment)'
fi
printf '\n'
audit_log "os-detect" "uname=$PP_OS version=$PP_OS_VERSION pep668=$PP_PEP668 id_like=$PP_OS_LIKE" 0 ""

# R2 fix (DevOps H3): Homebrew refuses to run as root since 2019. Detect
# EUID=0 before dispatching brew and bail with a clear error rather than
# letting brew's "Don't run as root" abort show up as a confused install
# failure. Apply only to the macos path since Linux installs frequently
# run via sudo legitimately.
if [ "$PP_OS" = "macos" ] && [ "$(id -u)" = "0" ]; then
  err "running as root on macOS — Homebrew refuses root."
  err "Re-run without sudo: ./bin/install.sh"
  audit_log "root-on-macos" "id -u returned 0" 1 "brew won't run as root"
  exit 1
fi

# R2 fix (DevOps M2): non-TTY stdin without --yes is the curl-pipe footgun.
# read returns EOF immediately, ans="" defaults to Y in every prompt → full
# silent auto-install. Detect and require --yes for this mode.
if ! [ -t 0 ] && [ "$PP_YES" != "1" ]; then
  err "Non-interactive stdin detected without --yes."
  err "If you piped this installer (curl | bash) or ran it under CI without a TTY,"
  err "you must pass --yes explicitly to auto-accept prompts:"
  err "  ./bin/install.sh --yes"
  audit_log "non-tty-without-yes" "isatty(0)=0 PP_YES=0" 1 "refused to auto-accept silently"
  exit 1
fi

# Helper: detect whether the current OS matches one of the listed family
# names via ID or ID_LIKE. ID_LIKE is space-separated per the os-release spec.
# Used to route Debian/Ubuntu derivatives (Pop, Mint, Kali, Zorin, Elementary,
# Raspbian, etc.) to the apt-family branch even if ID isn't recognized.
_pp_os_in_family() {
  local target_family="$1"
  case " $target_family " in
    *" $PP_OS "*) return 0 ;;
  esac
  for like in $PP_OS_LIKE; do
    case " $target_family " in
      *" $like "*) return 0 ;;
    esac
  done
  return 1
}

# Pick the LLM install command per OS + PEP 668 status.
# Each branch is explicit so the user sees what we're about to do.
#
# R2 fixes:
# - macOS no longer dispatches `brew install llm` (formula doesn't exist in
#   Homebrew core — Code-reviewer H3, DevOps M5). Now: brew install pipx +
#   pipx install llm.
# - Alpine package is `py3-pipx`, not `pipx` (DevOps H1).
# - ID_LIKE is now consulted via _pp_os_in_family so derivatives route correctly
#   (Code-reviewer M3, GPT MEDIUM).
PIP_INSTALL_LLM=""
if _pp_os_in_family "macos"; then
  # Homebrew core has no `llm` formula. Use pipx (via brew install pipx if
  # missing). Falls back to pip3 --user only if both brew AND pipx are absent.
  if command -v pipx >/dev/null 2>&1; then
    PIP_INSTALL_LLM="pipx install 'llm>=0.20,<1.0'"
  elif command -v brew >/dev/null 2>&1; then
    PIP_INSTALL_LLM="brew install pipx && pipx install 'llm>=0.20,<1.0'"
  elif command -v pip3 >/dev/null 2>&1; then
    # Last-resort on macOS without brew or pipx. PEP 668 is not enforced
    # by the macOS system python (/usr/bin/python3 from CLT) so --user works.
    PIP_INSTALL_LLM="pip3 install --user 'llm>=0.20,<1.0'"
  fi
elif _pp_os_in_family "ubuntu debian linuxmint pop kali zorin elementary raspbian neon"; then
  if command -v pipx >/dev/null 2>&1; then
    PIP_INSTALL_LLM="pipx install 'llm>=0.20,<1.0'"
  elif [ "$PP_PEP668" = "1" ]; then
    PIP_INSTALL_LLM="sudo apt-get update && sudo apt-get install -y pipx && pipx install 'llm>=0.20,<1.0'"
  elif command -v pip3 >/dev/null 2>&1; then
    PIP_INSTALL_LLM="pip3 install --user 'llm>=0.20,<1.0'"
  fi
elif _pp_os_in_family "fedora rhel centos rocky almalinux"; then
  if command -v pipx >/dev/null 2>&1; then
    PIP_INSTALL_LLM="pipx install 'llm>=0.20,<1.0'"
  elif command -v dnf >/dev/null 2>&1; then
    PIP_INSTALL_LLM="sudo dnf install -y pipx && pipx install 'llm>=0.20,<1.0'"
  elif command -v pip3 >/dev/null 2>&1; then
    PIP_INSTALL_LLM="pip3 install --user 'llm>=0.20,<1.0'"
  fi
elif _pp_os_in_family "arch manjaro"; then
  if command -v pipx >/dev/null 2>&1; then
    PIP_INSTALL_LLM="pipx install 'llm>=0.20,<1.0'"
  elif command -v pacman >/dev/null 2>&1; then
    PIP_INSTALL_LLM="sudo pacman -S --noconfirm python-pipx && pipx install 'llm>=0.20,<1.0'"
  fi
elif _pp_os_in_family "alpine"; then
  if command -v pipx >/dev/null 2>&1; then
    PIP_INSTALL_LLM="pipx install 'llm>=0.20,<1.0'"
  elif command -v apk >/dev/null 2>&1; then
    # Alpine community repo package name is py3-pipx, not pipx (R2 DevOps H1).
    # Also: Alpine Docker has no sudo. Try without sudo if we're root.
    if [ "$(id -u)" = "0" ]; then
      PIP_INSTALL_LLM="apk add --no-cache py3-pipx && pipx install 'llm>=0.20,<1.0'"
    else
      PIP_INSTALL_LLM="sudo apk add --no-cache py3-pipx && pipx install 'llm>=0.20,<1.0'"
    fi
  fi
else
  # Unknown OS — best-effort cascade.
  if command -v pipx >/dev/null 2>&1; then
    PIP_INSTALL_LLM="pipx install 'llm>=0.20,<1.0'"
  elif command -v pip3 >/dev/null 2>&1; then
    PIP_INSTALL_LLM="pip3 install --user 'llm>=0.20,<1.0'"
  fi
fi

# R3 + R4 fix (PATH ordering + scope discipline): everything below is
# gated on the install command actually using pipx, so we don't pollute
# the shell environment for installs that take a different path.
case "$PIP_INSTALL_LLM" in
  *pipx*)
    # Prepend ~/.local/bin to PATH BEFORE check_or_install llm so the
    # post-install `command -v llm` check at line ~600 can find pipx's
    # installation. R2 had this AFTER which meant llm was silently
    # invisible until the next shell.
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac

    # R3 + R4 fix: pipx 1.x refuses to run as root unless PIPX_HOME +
    # PIPX_BIN_DIR point to system locations. Linux containers
    # (Alpine/Ubuntu Docker) default to root. Scope these exports to the
    # pipx-install branch only (R4 GPT HIGH-2: don't pollute env for
    # non-pipx installs).
    if [ "$(id -u)" = "0" ] && [ "$PP_OS" != "macos" ]; then
      export PIPX_HOME="${PIPX_HOME:-/opt/pipx}"
      export PIPX_BIN_DIR="${PIPX_BIN_DIR:-/usr/local/bin}"
      # Also prepend PIPX_BIN_DIR to PATH so the post-install check finds
      # llm on minimal images where /usr/local/bin isn't in default PATH
      # (R4 GPT HIGH-3 + Debugger theoretical-but-narrow concern).
      case ":$PATH:" in
        *":$PIPX_BIN_DIR:"*) ;;
        *) export PATH="$PIPX_BIN_DIR:$PATH" ;;
      esac
    fi
    ;;
esac

check_or_install jq "$PKG_INSTALL_JQ"
check_or_install llm "$PIP_INSTALL_LLM"

# Post-install: run pipx ensurepath so the user's NEXT shell session finds
# llm without manual PATH editing. Idempotent — pipx ensurepath is safe to
# re-run. Don't fail the install if ensurepath errors (e.g. on root or in
# CI where shell rc files don't exist).
case "$PIP_INSTALL_LLM" in
  *pipx*)
    if command -v pipx >/dev/null 2>&1 && [ "$PP_DRY_RUN" != "1" ]; then
      pipx ensurepath >/dev/null 2>&1 || true
    fi
    ;;
esac

# pip --user installs to ~/.local/bin (Linux) or ~/Library/Python/.../bin (macOS),
# which may not be on PATH. Verify llm is now invocable; print PATH hint if not.
# Dry-run can't actually have installed anything, so skip the check there.
if [ "$PP_DRY_RUN" != "1" ] && ! command -v llm >/dev/null 2>&1; then
  warn "'llm' was installed but is not on PATH."
  warn "Add this to your shell rc (\$HOME/.bashrc / .zshrc) and restart the shell:"
  printf '    export PATH="$HOME/.local/bin:$PATH"\n'
  warn "Then re-run this installer."
  audit_log "dep-install" "llm-on-path" 1 "PATH missing ~/.local/bin"
  exit 1
fi

# === Step 3: OpenAI key ===
step "OpenAI API key"
if [ "$PP_DRY_RUN" = "1" ]; then
  printf '  [DRY-RUN] Would check `llm keys list` and prompt for OpenAI key if missing.\n'
  audit_log "openai-key-check" "llm keys list" 0 "dry-run"
elif llm keys list 2>/dev/null | grep -q '^openai$'; then
  ok "openai key already configured in llm CLI"
  audit_log "openai-key-check" "llm keys list" 0 "already present"
elif [ "$PP_YES" = "1" ]; then
  warn "Skipping OpenAI key prompt (--yes). Configure later: llm keys set openai"
  audit_log "openai-key-set" "skipped under --yes" 0 ""
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
    # Review fix MEDIUM-2: previously a failed `llm keys set openai` only
    # logged + warned, then the installer continued to print "✓ Pair Polymath
    # installed." That's a lie when the key never landed. Now: abort, with a
    # clear remediation step.
    if ! printf '%s\n' "$openai_key" | llm keys set openai 2>/dev/null; then
      err "failed to store openai key (llm keys set openai returned non-zero)"
      err "fix this then re-run: llm keys set openai"
      audit_log "openai-key-set" "llm keys set openai" 1 "failure"
      exit 1
    fi
    ok "openai key stored"
    audit_log "openai-key-set" "llm keys set openai" 0 ""
  else
    warn "Skipping key setup. Configure later: llm keys set openai"
    audit_log "openai-key-set" "skipped (empty input)" 0 ""
  fi
fi

# === Step 4: User config dir ===
step "Setting up user override directory"
if [ "$PP_DRY_RUN" = "1" ]; then
  printf '  [DRY-RUN] mkdir -p %s/{lenses,prompts,cache,config}\n' "$USER_CONFIG_DIR"
  printf '  [DRY-RUN] chmod 700 %s\n' "$USER_CONFIG_DIR"
  printf '  [DRY-RUN] Would write %s/config/user.env if absent\n' "$USER_CONFIG_DIR"
  audit_log "user-config-dir" "mkdir/chmod $USER_CONFIG_DIR" 0 "dry-run"
else
  _pp_run "mkdir-user-config" mkdir -p \
    "$USER_CONFIG_DIR/lenses" \
    "$USER_CONFIG_DIR/prompts" \
    "$USER_CONFIG_DIR/cache" \
    "$USER_CONFIG_DIR/config"
  chmod 700 "$USER_CONFIG_DIR" 2>/dev/null || true
  audit_log "chmod-user-config" "chmod 700 $USER_CONFIG_DIR" 0 ""
  # Tighten ~/.claude/cache to 700 ONLY when we create it fresh. Never chmod
  # a user-existing directory — they may have intentionally relaxed perms
  # (e.g. shared dev box) and we shouldn't override that decision.
  if [ ! -d "$CLAUDE_DIR/cache" ]; then
    _pp_run "mkdir-claude-cache" mkdir -p "$CLAUDE_DIR/cache"
    chmod 700 "$CLAUDE_DIR/cache" 2>/dev/null || true
  fi
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
    audit_log "write-user-env" "user.env stub" 0 ""
  else
    ok "$USER_CONFIG_DIR/config/user.env already exists — preserved"
    audit_log "write-user-env" "preserved existing" 0 ""
  fi
fi

# === Step 5: Smoke-test BEFORE touching settings.json (review fix H3) ===
# If statusline.sh is broken in this checkout, fail before pointing settings
# at it. Otherwise we'd leave the user with a broken statusLine.
step "Smoke-testing statusline before activating"
if [ -f "$PP_ROOT/test/fixtures/stdin-sample.json" ]; then
  if [ "$PP_DRY_RUN" = "1" ]; then
    printf '  [DRY-RUN] Would smoke-test statusline.sh against fixture.\n'
    audit_log "smoke-test" "statusline.sh < fixture" 0 "dry-run"
  else
    smoke_stderr=$(mktemp 2>/dev/null) || smoke_stderr="/tmp/pp-smoke-$$"
    smoke_rc=0
    cat "$PP_ROOT/test/fixtures/stdin-sample.json" \
      | bash "$PP_ROOT/bin/statusline.sh" >/dev/null 2>"$smoke_stderr" \
      || smoke_rc=$?
    smoke_tail=""
    [ -s "$smoke_stderr" ] && smoke_tail=$(tail -c 500 "$smoke_stderr")
    rm -f "$smoke_stderr"
    if [ "$smoke_rc" = "0" ]; then
      ok "statusline.sh exits 0 on sample input"
      audit_log "smoke-test" "cat fixture | bin/statusline.sh" 0 "$smoke_tail"
    else
      err "statusline.sh failed smoke test — aborting; settings.json untouched."
      audit_log "smoke-test" "cat fixture | bin/statusline.sh" "$smoke_rc" "$smoke_tail"
      exit 1
    fi
  fi
else
  warn "no smoke fixture found; skipping pre-flight test"
  audit_log "smoke-test" "skipped" 0 "no fixture"
fi

# === Step 6: Merge into settings.json ===
step "Merging into $SETTINGS_FILE"

# Quote paths so the shell command string in settings.json survives word-splitting
# when PP_ROOT contains spaces (review fix M2). Single-quoted around the path
# means bash strips the quotes and runs the path as one argument.
SL_CMD="bash '${PP_ROOT}/bin/statusline.sh'"
HOOK_USER_CMD="'${PP_ROOT}/hooks/inject-monitor-insight.sh'"
HOOK_POST_CMD="'${PP_ROOT}/hooks/cache-test-result.sh'"
# v0.5.1: SessionEnd hook is a no-op when PP_OAR_ENABLE=0 (default), so
# registering it now is harmless and unblocks v0.5.2 OAR rollout.
HOOK_SESSION_END_CMD="'${PP_ROOT}/hooks/session-end.sh'"

if [ "$PP_DRY_RUN" = "1" ]; then
  printf '  [DRY-RUN] Would back up %s\n' "$SETTINGS_FILE"
  printf '  [DRY-RUN] Would merge statusLine + 3 hooks via jq into %s\n' "$SETTINGS_FILE"
  audit_log "settings-merge" "jq ... > $SETTINGS_FILE" 0 "dry-run"
else
  if [ -f "$SETTINGS_FILE" ]; then
    bak="${SETTINGS_FILE}.bak.$(date +%s)"
    cp "$SETTINGS_FILE" "$bak"
    ok "backup: $bak"
    audit_log "settings-backup" "cp $SETTINGS_FILE $bak" 0 ""

    # Review fix H1: if a different statusLine is already set, prompt before clobber.
    existing_sl=$(jq -r '.statusLine?.command // ""' "$SETTINGS_FILE" 2>/dev/null)
    install_statusline=1
    if [ -n "$existing_sl" ] && [ "$existing_sl" != "$SL_CMD" ]; then
      warn "Existing statusLine detected:"
      printf '    %s\n' "$existing_sl"
      prompt "Replace with Pair Polymath statusLine? [y/N]"
      read_ans
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
  tmp=$(mktemp "${SETTINGS_FILE}.XXXXXX") || { err "mktemp failed"; audit_log "settings-merge" "mktemp" 1 "failed"; exit 1; }
  merge_stderr=$(mktemp 2>/dev/null) || merge_stderr="/tmp/pp-merge-$$"
  merge_rc=0
  jq --arg sl "$SL_CMD" \
     --arg hook_user "$HOOK_USER_CMD" \
     --arg hook_post "$HOOK_POST_CMD" \
     --arg hook_session_end "$HOOK_SESSION_END_CMD" \
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
    |
    # v0.5.1: SessionEnd hook — append if not already present (idempotent).
    # Hook script is a no-op when PP_OAR_ENABLE=0 (default), so registration
    # is safe regardless of OAR rollout state.
    (.hooks.SessionEnd //= [])
    | (.hooks.SessionEnd |= (
        if any(.[]; .hooks[]?.command == $hook_session_end) then .
        else . + [{matcher: "", hooks: [{type: "command", command: $hook_session_end, timeout: 3}]}]
        end))
  ' "$SETTINGS_FILE" > "$tmp" 2>"$merge_stderr" || merge_rc=$?
  merge_tail=""
  [ -s "$merge_stderr" ] && merge_tail=$(tail -c 500 "$merge_stderr")
  rm -f "$merge_stderr"

  if [ "$merge_rc" != "0" ] || ! jq empty "$tmp" 2>/dev/null; then
    err "Merged settings.json is invalid JSON — aborting (original preserved)."
    audit_log "settings-merge" "jq merge" "${merge_rc:-1}" "${merge_tail:-invalid JSON}"
    rm -f "$tmp"
    exit 1
  fi

  mv "$tmp" "$SETTINGS_FILE"
  if [ "$install_statusline" = "1" ]; then
    ok "settings.json updated (statusLine + 3 hooks)"
    audit_log "settings-merge" "jq merge → $SETTINGS_FILE" 0 "statusLine + 3 hooks"
  else
    ok "settings.json updated (3 hooks; existing statusLine preserved)"
    audit_log "settings-merge" "jq merge → $SETTINGS_FILE" 0 "3 hooks only"
  fi
fi

# === Done ===
audit_log "install-complete" "bin/install.sh" 0 ""
if [ "$PP_DRY_RUN" = "1" ]; then
  printf '\n\033[1m\033[32m✓ Pair Polymath dry-run complete.\033[0m No filesystem changes were made.\n'
else
  printf '\n\033[1m\033[32m✓ Pair Polymath installed.\033[0m\n'
  printf '\n  Next: open a new Claude Code session.\n'
  printf '  The first lens cycle completes within ~5 min of activity.\n'
  printf '\n  Status check: \033[1mbash %s/bin/polymath status\033[0m\n' "$PP_ROOT"
  printf '  Override config: edit \033[1m%s/config/user.env\033[0m\n' "$USER_CONFIG_DIR"
  printf '  Custom lens: drop JSON into \033[1m%s/lenses/\033[0m\n' "$USER_CONFIG_DIR"
  printf '  Custom prompt: drop .md into \033[1m%s/prompts/\033[0m\n' "$USER_CONFIG_DIR"
  printf '  Audit log: \033[1m%s\033[0m\n' "$PP_AUDIT_LOG"
fi
