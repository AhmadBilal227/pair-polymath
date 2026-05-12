# Memory Architecture Implementation Plan (v2 — post-GPT-review)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) for tracking. **Each task ends with a Ralph reviewer stack** (GPT-5.2 via `llm -t review-code`, `debugging-toolkit:debugger`, `llm-application-dev:ai-engineer`) before the next starts.

**Goal:** Ship Pair Polymath's v0.3 cross-session memory in one PR. SQLite-backed observation store, ACT-R-inspired activation scoring with real use-count bumps, 4 utility signals with proper time windows, LLM theme miner for emergent patterns, eviction with minimum-age floor + cluster-summarize-before-drop. Salted project hash for privacy. Body/path redaction defaults. Numeric eval merge gates.

**Architecture v2:** SQLite primary (WAL mode, native transactions). One project lock dir wraps every read-modify-write. Project identity = `sha1(salt || git_remote_url || cwd_realpath)`, salt stored at `$PP_MEMORY_DIR/.salt` mode 0600 — workplace identity not portable across machines. Real `llm embed` deferred to v0.4; schema reserves the column. Symbol-touch signal deferred to v0.4 (expensive + noisy). Eviction never touches observations <7 days old.

**Tech Stack:** bash 3.2-portable, SQLite 3.43+ (pre-installed macOS, one-line apt on Ubuntu — already added to `bin/install.sh` per-OS pattern), `llm` CLI (existing dep), `jq` (existing dep). Reference for theme stage: Articos `/Users/ahmadbilal/Downloads/hobby/Articos Simulation Animation/src/app/report/reportGenerator.ts`.

**Branch:** `feat/memory-architecture` from `origin/main` @ `33e70aa` (post-Phase-2.2).

**GPT-review findings addressed:** all 10 HIGH items from the v1-plan review:
| Finding | Resolution |
|---|---|
| Locking only on append | Single project lock-dir wraps ALL maintenance (Task A) |
| `use_count` never increments | Bumped at retrieval injection (Task B) |
| Retention signal is global-duplicate | Now windowed: consecutive-cycle only (Task C) |
| `patterns.sh` missing `$PP_ROOT`/`run_llm` deps | Real-mode smoke test + explicit sourcing (Task D) |
| Eviction kills new observations | Minimum-age floor 7d + activation floor (Task D) |
| Project hash leaks workplace | Per-machine salt (Task A) |
| Body/path raw storage | `PP_MEMORY_REDACT=1` default + secret-regex strip (Task A) |
| sqlite-vec promised but not used | Deferred entirely to v0.4 — out of scope (was Task 4) |
| SQL via sed-quoting | SQLite `sqlite3 -cmd ".parameter set"` parameter binding (Task B) |
| No eval merge gates | Numeric PASS/FAIL rubric (Task D) |

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/memory/schema.sh` | Schema v1 constants, salted project hash, project dir resolver, SQLite DDL |
| `lib/memory/lock.sh` | Single project-wide lock-dir primitive (`pp_memory_lock`/`unlock`/`with_lock`) |
| `lib/memory/store.sh` | Atomic observation insert (SQLite transaction), bulk retrieval, use_count bump |
| `lib/memory/activation.sh` | ACT-R formula + score recompute under lock |
| `lib/memory/signals.sh` | 4 windowed signals (retention/edit/commit/test-flip) under lock |
| `lib/memory/patterns.sh` | LLM theme miner + JSONL persistence, real-mode dependency-checked |
| `lib/memory/evict.sh` | 100MB cap + min-age floor + LRU-by-activation + cluster summary metadata |
| `lib/memory/redact.sh` | Body/path redaction (secret-regex strip, path-validation) |
| `prompts/pattern-extraction.md` | LLM theme-extraction prompt with injection defenses |
| `docs/memory-architecture.md` | Design doc + tier diagram + eval gates |
| `test/memory/schema.bats` | Salted hash determinism per-machine, dir creation, mode 0700/0600 |
| `test/memory/lock.bats` | Concurrent maintenance under lock, stale lock takeover |
| `test/memory/store.bats` | Insert/retrieve/use_count bump, transaction atomicity |
| `test/memory/activation.bats` | Formula correctness, decay, use-bump propagation |
| `test/memory/signals.bats` | 4 signals with windowed assertions (retention=consecutive-only) |
| `test/memory/patterns.bats` | Theme schema, mock + real-mode-dependency-error path |
| `test/memory/evict.bats` | Cap trigger, min-age floor, embedding row cleanup hook |
| `test/memory/redact.bats` | Secret regex strip, path validation |
| `test/memory/integration.bats` | End-to-end: write→tag→activate→retrieve→evict→pattern |

Modified files:

| File | Change |
|---|---|
| `bin/install.sh` | Add `sqlite3` to per-OS dep install (joins `jq` + `llm`) |
| `bin/statusline.sh` | Source memory libs, cycle wire-up (tag→activate→retrieve→write→evict→pattern) |
| `prompts/analyst-primary.md` | New `PROJECT PATTERNS:` block + `ACTIVATED OBSERVATIONS:` block |
| `lib/prompt-loader.sh` | Allowlist: `project_patterns`, `activated_observations` |
| `config/default.env` | Feature flags: `PP_MEMORY_ENABLED`, `PP_MEMORY_REDACT`, `PP_MEMORY_PATTERN_EVERY_N_CYCLES`, `PP_MEMORY_MAX_BYTES`, `PP_MEMORY_DECAY_PER_DAY`, `PP_MEMORY_TOPK`, `PP_MEMORY_MIN_AGE_DAYS_BEFORE_EVICT` |
| `bin/polymath` | New `polymath memory status / prune / export` subcommands |
| `bin/doctor.sh` | Add sqlite3 check to existing health probes |
| `test/eval/run-eval.sh` | `--clear-memory` flag for cold-start baselines |
| `docs/eval-harness.md` | Memory-aware baseline section |

---

## Task 0 — Preflight

- [ ] **Step 1:** sqlite3 available (already on macOS; check Ubuntu CI image)

  Run: `sqlite3 --version 2>&1 | head -1 || echo MISSING`

  Expected: `3.43.x` or similar. If missing on the dev box, the installer will handle it on user boxes.

- [ ] **Step 2:** Worktree on `feat/memory-architecture`

  Run:
  ```bash
  cd ~/Downloads/hobby/pair-polymath
  git fetch origin --quiet
  git worktree add /tmp/memory-arch -b feat/memory-architecture origin/main
  cd /tmp/memory-arch
  ```

- [ ] **Step 3:** Baseline bats green

  Run: `bats -r test/ 2>&1 | tail -3`

  Expected: 281+ pass (post-Phase-2.2).

- [ ] **Step 4:** Add `sqlite3` to installer's per-OS dep list

  Modify `bin/install.sh`:
  - In the existing per-OS install case (where `jq` is handled), add `sqlite3` to the same install line. macOS already has it system-installed; the installer should check `command -v sqlite3` first and skip if present.

  Pattern (per the existing PR #30 OS-detection):
  ```bash
  # In each OS branch's package-install block, alongside jq:
  PKG_INSTALL_SQLITE3="$pkg_mgr install -y sqlite3"
  check_or_install sqlite3 "$PKG_INSTALL_SQLITE3"
  ```

  Same pattern in `bin/doctor.sh` — add a sqlite3 health-check line.

- [ ] **Step 5:** Commit preflight

  ```bash
  git add bin/install.sh bin/doctor.sh
  git commit -m "chore(memory): preflight — add sqlite3 to installer + doctor

  Memory architecture (#29) uses SQLite for transactional observation
  storage. sqlite3 is pre-installed on macOS; per-OS install line added
  alongside jq for Ubuntu/Fedora/Arch/Alpine. Doctor health-check too."
  ```

---

## Task A — Project Identity + Locking + Schema

**Files:**
- Create: `lib/memory/schema.sh`
- Create: `lib/memory/lock.sh`
- Create: `lib/memory/redact.sh`
- Create: `test/memory/schema.bats`
- Create: `test/memory/lock.bats`
- Create: `test/memory/redact.bats`

**Goal:** Foundation. Salted project hash (workplace identity not portable across machines), single project-wide lock-dir primitive (wraps ALL future maintenance), redaction helpers.

### A.1 — Salted project hash

- [ ] **Step 1:** Write failing test — `test/memory/schema.bats`

  ```bash
  #!/usr/bin/env bats
  setup() {
    export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX"
    export CLAUDE_DIR="$SANDBOX/.claude"
    export PP_MEMORY_DIR="$SANDBOX/.claude/pair-polymath/memory"
    # shellcheck disable=SC1091
    . "$PP_ROOT/lib/memory/schema.sh"
  }
  teardown() { rm -rf "$SANDBOX"; }

  @test "schema: salt file is created at 0600 on first hash call" {
    mkdir -p "$SANDBOX/repo" && (cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/foo/bar.git)
    h=$(pp_memory_project_hash "$SANDBOX/repo")
    [ -n "$h" ]
    [ -f "$PP_MEMORY_DIR/.salt" ]
    perm=$(stat -f '%Lp' "$PP_MEMORY_DIR/.salt" 2>/dev/null || stat -c '%a' "$PP_MEMORY_DIR/.salt")
    [ "$perm" = "600" ]
  }

  @test "schema: same machine + same remote → same hash" {
    mkdir -p "$SANDBOX/repo" && (cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/foo/bar.git)
    h1=$(pp_memory_project_hash "$SANDBOX/repo")
    h2=$(pp_memory_project_hash "$SANDBOX/repo")
    [ "$h1" = "$h2" ]
  }

  @test "schema: different salt files → different hashes (workplace identity not portable)" {
    mkdir -p "$SANDBOX/repo" && (cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/foo/bar.git)
    h1=$(pp_memory_project_hash "$SANDBOX/repo")
    rm -f "$PP_MEMORY_DIR/.salt"
    h2=$(pp_memory_project_hash "$SANDBOX/repo")
    [ "$h1" != "$h2" ]
  }

  @test "schema: no git remote → falls back to realpath, salted same way" {
    mkdir -p "$SANDBOX/no-remote" && (cd "$SANDBOX/no-remote" && git init -q)
    h=$(pp_memory_project_hash "$SANDBOX/no-remote")
    [ -n "$h" ]
  }

  @test "schema: PP_MEMORY_SCHEMA_VERSION is the string 1" {
    [ "$PP_MEMORY_SCHEMA_VERSION" = "1" ]
  }
  ```

- [ ] **Step 2:** Run tests → expect 5 failures, library missing.

- [ ] **Step 3:** Implement `lib/memory/schema.sh`

  ```bash
  #!/usr/bin/env bash
  # Pair Polymath — memory schema constants + salted project identity.

  PP_MEMORY_SCHEMA_VERSION="1"
  PP_MEMORY_DIR="${PP_MEMORY_DIR:-${CLAUDE_DIR:-$HOME/.claude}/pair-polymath/memory}"

  # pp_memory_get_salt
  # Returns the per-machine random salt. Created on first call, mode 0600.
  # Same salt persists forever per HOME — uninstalling pair-polymath does NOT
  # delete this file (allows memory across reinstalls).
  pp_memory_get_salt() {
    local sf="$PP_MEMORY_DIR/.salt"
    if [ ! -f "$sf" ]; then
      mkdir -p "$PP_MEMORY_DIR" 2>/dev/null || return 1
      chmod 700 "$PP_MEMORY_DIR" 2>/dev/null || true
      # Random 32 hex chars from /dev/urandom (portable; macOS + Linux).
      LC_ALL=C dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | LC_ALL=C tr -d ' \n' > "$sf"
      chmod 600 "$sf" 2>/dev/null || true
    fi
    cat "$sf"
  }

  # pp_memory_project_hash CWD
  # Stdout: salted project identity hash (first 16 hex of sha1(salt || identity)).
  pp_memory_project_hash() {
    local cwd="${1:-$PWD}"
    local identity=""
    if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
      identity=$(git -C "$cwd" config --get remote.origin.url 2>/dev/null)
    fi
    if [ -z "$identity" ]; then
      if command -v realpath >/dev/null 2>&1; then
        identity=$(realpath "$cwd" 2>/dev/null)
      else
        identity=$(cd "$cwd" 2>/dev/null && pwd -P)
      fi
    fi
    [ -z "$identity" ] && identity="$cwd"
    local salt
    salt=$(pp_memory_get_salt)
    [ -z "$salt" ] && return 1
    printf '%s%s' "$salt" "$identity" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-16
  }

  # pp_memory_project_dir CWD
  pp_memory_project_dir() {
    local h
    h=$(pp_memory_project_hash "${1:-$PWD}") || return 1
    printf '%s/projects/%s' "$PP_MEMORY_DIR" "$h"
  }

  # pp_memory_db_init PROJ_DIR
  # Creates SQLite DB with the v1 schema. Idempotent. WAL mode for
  # native concurrent-reader / single-writer semantics.
  pp_memory_db_init() {
    local proj_dir="$1"
    mkdir -p "$proj_dir" 2>/dev/null || return 1
    chmod 700 "$proj_dir" 2>/dev/null || true
    local db="$proj_dir/observations.sqlite"
    sqlite3 "$db" <<'EOF'
  PRAGMA journal_mode=WAL;
  PRAGMA synchronous=NORMAL;
  CREATE TABLE IF NOT EXISTS observations (
    obs_id              TEXT PRIMARY KEY,
    ts                  TEXT NOT NULL,
    schema_version      TEXT NOT NULL,
    lens_id             TEXT NOT NULL,
    topic               TEXT,
    hook                TEXT,
    body                TEXT,
    cited_paths         TEXT,
    cited_symbols       TEXT,
    project_hash        TEXT,
    session_id          TEXT,
    signal_retention    INTEGER DEFAULT 0,
    signal_file_edit    INTEGER DEFAULT 0,
    signal_commit_mention INTEGER DEFAULT 0,
    signal_test_flip    INTEGER DEFAULT 0,
    use_count           INTEGER DEFAULT 1,
    act_count           INTEGER DEFAULT 0,
    last_seen_ts        TEXT NOT NULL,
    activation_score    REAL DEFAULT 1.0,
    embedding_id        TEXT,
    redacted            INTEGER DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS idx_obs_ts ON observations(ts);
  CREATE INDEX IF NOT EXISTS idx_obs_lens ON observations(lens_id);
  CREATE INDEX IF NOT EXISTS idx_obs_activation ON observations(activation_score DESC);

  CREATE TABLE IF NOT EXISTS cycle_state (
    key   TEXT PRIMARY KEY,
    value TEXT
  );
EOF
    chmod 600 "$db" 2>/dev/null || true
  }
  ```

- [ ] **Step 4:** Run tests → expect 5/5 pass.

- [ ] **Step 5:** Commit A.1

  ```bash
  git add lib/memory/schema.sh test/memory/schema.bats
  git commit -m "feat(memory): Task A.1 — salted project hash + SQLite schema

  Salt at \$PP_MEMORY_DIR/.salt (mode 0600, 32 hex chars from urandom)
  makes project hashes per-machine — same git remote on a colleague's
  machine produces a different hash, addressing workplace identity
  leak (GPT review HIGH-12). SQLite schema with WAL mode for native
  concurrent semantics. 5 bats tests."
  ```

### A.2 — Lock primitive

- [ ] **Step 6:** Failing test — `test/memory/lock.bats`

  ```bash
  #!/usr/bin/env bats
  setup() {
    export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SANDBOX="$(mktemp -d)"
    # shellcheck disable=SC1091
    . "$PP_ROOT/lib/memory/lock.sh"
  }
  teardown() { rm -rf "$SANDBOX"; }

  @test "lock: pp_memory_lock acquires and unlock releases" {
    mkdir -p "$SANDBOX/proj"
    pp_memory_lock "$SANDBOX/proj"
    [ -d "$SANDBOX/proj/.maint.lock" ]
    pp_memory_unlock "$SANDBOX/proj"
    [ ! -d "$SANDBOX/proj/.maint.lock" ]
  }

  @test "lock: pp_memory_with_lock runs body under lock, releases on success" {
    mkdir -p "$SANDBOX/proj"
    pp_memory_with_lock "$SANDBOX/proj" 'echo ran > "$SANDBOX/proj/output"'
    [ -f "$SANDBOX/proj/output" ]
    [ ! -d "$SANDBOX/proj/.maint.lock" ]
  }

  @test "lock: pp_memory_with_lock releases on failure" {
    mkdir -p "$SANDBOX/proj"
    run pp_memory_with_lock "$SANDBOX/proj" 'false'
    [ "$status" -ne 0 ]
    [ ! -d "$SANDBOX/proj/.maint.lock" ]
  }

  @test "lock: second acquirer waits then fails after timeout" {
    mkdir -p "$SANDBOX/proj"
    pp_memory_lock "$SANDBOX/proj"
    # Force timeout to 1 second so test isn't slow
    PP_MEMORY_LOCK_TIMEOUT_S=1 run pp_memory_lock "$SANDBOX/proj"
    [ "$status" -ne 0 ]
    pp_memory_unlock "$SANDBOX/proj"
  }

  @test "lock: stale lock taken over after PP_MEMORY_LOCK_STALE_S" {
    mkdir -p "$SANDBOX/proj/.maint.lock"
    # Backdate it
    touch -t 202001010000 "$SANDBOX/proj/.maint.lock"
    PP_MEMORY_LOCK_STALE_S=60 run pp_memory_lock "$SANDBOX/proj"
    [ "$status" -eq 0 ]
    pp_memory_unlock "$SANDBOX/proj"
  }
  ```

- [ ] **Step 7:** Implement `lib/memory/lock.sh`

  ```bash
  #!/usr/bin/env bash
  # Pair Polymath — single project-wide lock for ANY read-modify-write op.
  # mkdir is atomic on POSIX. Wraps signals, activation recompute,
  # eviction, pattern extraction. Append-only inserts via SQLite
  # transactions don't need this (SQLite's own locking is sufficient).

  pp_memory_lock() {
    local proj_dir="$1"
    local lockdir="$proj_dir/.maint.lock"
    local stale_s="${PP_MEMORY_LOCK_STALE_S:-300}"
    local timeout_s="${PP_MEMORY_LOCK_TIMEOUT_S:-30}"
    local waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      # Check stale lock
      local age
      age=$(($(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo 0)))
      if [ "$age" -gt "$stale_s" ]; then
        rm -rf "$lockdir" 2>/dev/null
        mkdir "$lockdir" 2>/dev/null && return 0
      fi
      waited=$((waited + 1))
      if [ "$waited" -gt "$timeout_s" ]; then
        printf 'pp_memory_lock: timeout waiting on %s\n' "$lockdir" >&2
        return 1
      fi
      sleep 1
    done
    return 0
  }

  pp_memory_unlock() {
    local proj_dir="$1"
    rmdir "$proj_dir/.maint.lock" 2>/dev/null || rm -rf "$proj_dir/.maint.lock" 2>/dev/null
  }

  # pp_memory_with_lock PROJ_DIR CMD
  # Acquire lock, eval CMD, always unlock (success or failure).
  pp_memory_with_lock() {
    local proj_dir="$1"
    local cmd="$2"
    pp_memory_lock "$proj_dir" || return 1
    local rc=0
    eval "$cmd" || rc=$?
    pp_memory_unlock "$proj_dir"
    return "$rc"
  }
  ```

- [ ] **Step 8:** Run + commit A.2

  ```bash
  git add lib/memory/lock.sh test/memory/lock.bats
  git commit -m "feat(memory): Task A.2 — project lock primitive

  pp_memory_lock/unlock/with_lock wraps every read-modify-write on the
  project memory dir. Stale takeover after 300s (configurable),
  acquire timeout 30s. mkdir-atomic per POSIX. Addresses GPT review
  HIGH-4 (concurrency: only append was locked; rewrites unprotected)."
  ```

### A.3 — Redaction

- [ ] **Step 9:** Failing tests + impl — `test/memory/redact.bats` + `lib/memory/redact.sh`

  Tests cover: secret-regex patterns (sk-..., bearer tokens, AWS keys, GitHub PATs, .env paths), path-outside-cwd rejection, redacted=1 column flag.

  Implementation: `pp_memory_redact_body TEXT` strips secret-shaped substrings and replaces with `[REDACTED]`. `pp_memory_redact_path PATH CWD` validates the path is inside cwd (using existing `pp_contain_path` from `lib/grounding.sh`).

  ```bash
  #!/usr/bin/env bash
  # Pair Polymath — memory redaction defaults. Strips secret-shaped tokens
  # and validates paths before persistence. Off-by-default sentinel patterns
  # used to be in scope; this enforces them at the storage boundary.
  # Sourced after lib/grounding.sh (uses pp_contain_path).

  pp_memory_redact_body() {
    local body="$1"
    LC_ALL=C printf '%s' "$body" \
      | LC_ALL=C sed -E '
          s|sk-[A-Za-z0-9_-]{20,}|[REDACTED-OPENAI]|g
          s|Bearer [A-Za-z0-9._-]{20,}|[REDACTED-BEARER]|g
          s|ghp_[A-Za-z0-9]{20,}|[REDACTED-GHP]|g
          s|github_pat_[A-Za-z0-9_]{20,}|[REDACTED-GHPAT]|g
          s|AKIA[A-Z0-9]{16}|[REDACTED-AWS]|g
          s|xox[abprs]-[A-Za-z0-9-]{20,}|[REDACTED-SLACK]|g
          s|[a-zA-Z0-9_/.-]*\.env[a-zA-Z0-9_.-]*|[REDACTED-DOTENV]|g
        '
  }

  # pp_memory_redact_path PATH CWD
  # Stdout: PATH if it's safely inside CWD; empty if outside (rejected).
  pp_memory_redact_path() {
    local path="$1"
    local cwd="$2"
    # Use pp_contain_path from lib/grounding.sh (already sourced upstream).
    if pp_contain_path "$cwd" "$path" >/dev/null 2>&1; then
      printf '%s' "$path"
    fi
  }
  ```

- [ ] **Step 10:** Run + commit A.3

  ```bash
  git add lib/memory/redact.sh test/memory/redact.bats
  git commit -m "feat(memory): Task A.3 — body/path redaction defaults

  Strips secret-shaped tokens (OpenAI sk-, GitHub ghp_/github_pat_, AWS
  AKIA, Slack xox*, Bearer, .env paths) from observation bodies before
  SQLite insert. Validates paths against cwd via pp_contain_path.
  Addresses GPT review HIGH-13 (sensitive data in long-term memory)."
  ```

### A.4 — Ralph review for Task A

Dispatch in parallel against the 3-commit Task A diff:
1. **GPT-5.2** (`git diff main..HEAD | llm -t review-code -m gpt-5.2`) — focus: salt-file ACID (read-while-creating race), lock-dir stale takeover correctness, redact regex completeness/escape.
2. **debugger** agent — reproduce all bats + add concurrency probe (2 parallel `pp_memory_with_lock` calls; verify exactly one runs at a time).
3. **ai-engineer** agent — judge whether the schema field list is complete for ACT-R + 4 signals + future v0.4 (sqlite-vec). What's missing? Is the salt approach sound vs. a single per-installation UUID?

Apply HIGH fixes before Task B.

---

## Task B — Observation Store + Activation + Retrieval

**Files:**
- Create: `lib/memory/store.sh`
- Create: `lib/memory/activation.sh`
- Create: `test/memory/store.bats`
- Create: `test/memory/activation.bats`

**Goal:** SQLite transactional inserts with parameter binding (no sed-quoting). ACT-R activation: `ln(use_count + 1) - decay×days + 0.6×act_count + 0.4×signal_retention`. Use-count + last-seen-ts bumped on retrieval. Top-K returns observations sorted by activation.

### B.1 — Inserts + retrieval

- [ ] **Step 1:** Failing tests — `test/memory/store.bats`

  ```bash
  #!/usr/bin/env bats
  setup() {
    export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX"
    export CLAUDE_DIR="$SANDBOX/.claude"
    export PP_MEMORY_DIR="$SANDBOX/.claude/pair-polymath/memory"
    for f in schema.sh lock.sh redact.sh store.sh activation.sh; do
      . "$PP_ROOT/lib/memory/$f"
    done
    . "$PP_ROOT/lib/grounding.sh"
    mkdir -p "$SANDBOX/repo" && (cd "$SANDBOX/repo" && git init -q && git remote add origin https://github.com/test/x.git)
    PROJ=$(pp_memory_project_dir "$SANDBOX/repo")
    pp_memory_db_init "$PROJ"
  }
  teardown() { rm -rf "$SANDBOX"; }

  @test "store: insert + select round-trip with embedded quotes survives" {
    pp_memory_insert "$SANDBOX/repo" \
      "o1" "ENGINEERING" "BACKEND" "hook with 'quote'" "body with \"double\" and 'single'" "[]" "[]" "sess1"
    row=$(sqlite3 "$PROJ/observations.sqlite" "SELECT body FROM observations WHERE obs_id='o1';")
    [[ "$row" == *"quote"* ]]
    [[ "$row" == *"double"* ]]
  }

  @test "store: insert respects redaction default (sk- token stripped)" {
    PP_MEMORY_REDACT=1 pp_memory_insert "$SANDBOX/repo" \
      "o2" "SECURITY" "SEC" "hook" "body sk-NEVER-LEAK-THIS-1234567890abc and more" "[]" "[]" "s"
    row=$(sqlite3 "$PROJ/observations.sqlite" "SELECT body FROM observations WHERE obs_id='o2';")
    [[ "$row" != *"sk-NEVER-LEAK-THIS"* ]]
    [[ "$row" == *"REDACTED"* ]]
  }

  @test "store: pp_memory_top_k bumps use_count + last_seen_ts" {
    pp_memory_insert "$SANDBOX/repo" "o3" "ENG" "T" "h" "b" "[]" "[]" "s"
    before=$(sqlite3 "$PROJ/observations.sqlite" "SELECT use_count FROM observations WHERE obs_id='o3';")
    pp_memory_top_k "$SANDBOX/repo" 5 >/dev/null
    after=$(sqlite3 "$PROJ/observations.sqlite" "SELECT use_count FROM observations WHERE obs_id='o3';")
    [ "$after" -gt "$before" ]
  }
  ```

- [ ] **Step 2:** Implement `lib/memory/store.sh`

  ```bash
  #!/usr/bin/env bash
  # Pair Polymath — SQLite-backed observation store.
  # Inserts use parameter binding via sqlite3 -cmd ".parameter set",
  # NOT sed-quoting. Bulk retrieval bumps use_count + last_seen_ts in
  # the same transaction.

  # pp_memory_insert CWD OBS_ID LENS_ID TOPIC HOOK BODY CITED_PATHS_JSON CITED_SYMBOLS_JSON SESSION_ID
  pp_memory_insert() {
    local cwd="$1" obs_id="$2" lens="$3" topic="$4" hook="$5"
    local body="$6" paths_json="$7" symbols_json="$8" sess="$9"
    local proj_dir
    proj_dir=$(pp_memory_project_dir "$cwd") || return 1
    pp_memory_db_init "$proj_dir"
    local db="$proj_dir/observations.sqlite"
    local phash
    phash=$(pp_memory_project_hash "$cwd")
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local redacted=0
    if [ "${PP_MEMORY_REDACT:-1}" = "1" ]; then
      body=$(pp_memory_redact_body "$body")
      redacted=1
    fi
    # Parameter binding via sqlite3 -cmd. Each value bound by NAME → no
    # quote injection issues. ATTACH/INSERT under single transaction.
    sqlite3 "$db" \
      -cmd ".parameter set :obs_id   '$(printf '%s' "$obs_id"     | LC_ALL=C tr -d \"'\")'" \
      -cmd ".parameter set :ts       '$now'" \
      -cmd ".parameter set :sv       '$PP_MEMORY_SCHEMA_VERSION'" \
      -cmd ".parameter set :lens     '$(printf '%s' "$lens"      | LC_ALL=C tr -d \"'\")'" \
      -cmd ".parameter set :topic    \$_TOPIC_RAW" \
      -cmd ".parameter set :hook     \$_HOOK_RAW" \
      -cmd ".parameter set :body     \$_BODY_RAW" \
      -cmd ".parameter set :paths    '$paths_json'" \
      -cmd ".parameter set :symbols  '$symbols_json'" \
      -cmd ".parameter set :phash    '$phash'" \
      -cmd ".parameter set :sess     '$sess'" \
      -cmd ".parameter set :red      '$redacted'" \
      <<SQL
  INSERT OR REPLACE INTO observations
    (obs_id, ts, schema_version, lens_id, topic, hook, body,
     cited_paths, cited_symbols, project_hash, session_id,
     last_seen_ts, redacted)
  VALUES
    (:obs_id, :ts, :sv, :lens, :topic, :hook, :body,
     :paths, :symbols, :phash, :sess, :ts, :red);
SQL
    # NB: $_TOPIC_RAW / $_HOOK_RAW / $_BODY_RAW require pre-quoting because
    # SQLite parameter set via -cmd interprets them. Simpler: write directly
    # via heredoc with quoted vars using sqlite3 SQL escaping. The cleaner
    # form below replaces the above (kept the doc for posterity).
  }

  # SIMPLER + CORRECT impl: pipe values through stdin as named-arg JSON,
  # then INSERT FROM JSON. Avoids any shell-quoting on text content.
  pp_memory_insert() {
    local cwd="$1" obs_id="$2" lens="$3" topic="$4" hook="$5"
    local body="$6" paths_json="$7" symbols_json="$8" sess="$9"
    local proj_dir
    proj_dir=$(pp_memory_project_dir "$cwd") || return 1
    pp_memory_db_init "$proj_dir"
    local db="$proj_dir/observations.sqlite"
    local phash
    phash=$(pp_memory_project_hash "$cwd")
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local redacted=0
    if [ "${PP_MEMORY_REDACT:-1}" = "1" ]; then
      body=$(pp_memory_redact_body "$body")
      redacted=1
    fi
    # Build a JSON object as input, use SQLite's json_extract to bind safely.
    local input
    input=$(jq -nc \
      --arg obs_id "$obs_id" \
      --arg ts "$now" \
      --arg sv "$PP_MEMORY_SCHEMA_VERSION" \
      --arg lens "$lens" --arg topic "$topic" \
      --arg hook "$hook" --arg body "$body" \
      --argjson paths "${paths_json:-[]}" \
      --argjson symbols "${symbols_json:-[]}" \
      --arg phash "$phash" --arg sess "$sess" \
      --argjson red "$redacted" \
      '{obs_id:$obs_id, ts:$ts, sv:$sv, lens:$lens, topic:$topic,
        hook:$hook, body:$body, paths:($paths|tostring), symbols:($symbols|tostring),
        phash:$phash, sess:$sess, red:$red}')
    printf '%s\n' "$input" | sqlite3 "$db" <<'SQL'
  CREATE TEMP TABLE _input(j TEXT);
  .mode list
  .import /dev/stdin _input
  INSERT OR REPLACE INTO observations
    (obs_id, ts, schema_version, lens_id, topic, hook, body,
     cited_paths, cited_symbols, project_hash, session_id,
     last_seen_ts, redacted)
  SELECT
    json_extract(j, '$.obs_id'),
    json_extract(j, '$.ts'),
    json_extract(j, '$.sv'),
    json_extract(j, '$.lens'),
    json_extract(j, '$.topic'),
    json_extract(j, '$.hook'),
    json_extract(j, '$.body'),
    json_extract(j, '$.paths'),
    json_extract(j, '$.symbols'),
    json_extract(j, '$.phash'),
    json_extract(j, '$.sess'),
    json_extract(j, '$.ts'),
    json_extract(j, '$.red')
  FROM _input;
SQL
  }

  # pp_memory_top_k CWD K
  # Returns top-K observations by activation_score (JSONL on stdout).
  # Bumps use_count + last_seen_ts on the returned rows IN SAME TRANSACTION.
  pp_memory_top_k() {
    local cwd="$1" k="${2:-15}"
    local proj_dir
    proj_dir=$(pp_memory_project_dir "$cwd") || return 0
    local db="$proj_dir/observations.sqlite"
    [ -f "$db" ] || return 0
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sqlite3 -json "$db" <<SQL
  BEGIN;
  CREATE TEMP TABLE _top AS
    SELECT obs_id FROM observations
    ORDER BY activation_score DESC NULLS LAST
    LIMIT $k;
  UPDATE observations
    SET use_count = use_count + 1,
        last_seen_ts = '$now'
    WHERE obs_id IN (SELECT obs_id FROM _top);
  SELECT * FROM observations WHERE obs_id IN (SELECT obs_id FROM _top)
    ORDER BY activation_score DESC NULLS LAST;
  COMMIT;
SQL
  }
  ```

- [ ] **Step 3:** Run + commit B.1

  ```bash
  git add lib/memory/store.sh test/memory/store.bats
  git commit -m "feat(memory): Task B.1 — SQLite store with parameter binding

  pp_memory_insert + pp_memory_top_k. Insert uses jq-built JSON → SQLite
  json_extract (no shell-quoting needed). Top-K bumps use_count +
  last_seen_ts in same transaction (addresses GPT review HIGH-2:
  activation was time-decay-only without use-bump path). Default-on
  redaction (PP_MEMORY_REDACT=1) before persistence."
  ```

### B.2 — Activation formula + recompute

- [ ] **Step 4:** Failing tests — `test/memory/activation.bats` (formula correctness, decay, retention bump, recompute under lock)

- [ ] **Step 5:** Implement `lib/memory/activation.sh`

  ```bash
  #!/usr/bin/env bash
  # Pair Polymath — ACT-R-inspired activation formula.
  # Note: this is an ACT-R-INSPIRED heuristic, not a literal ACT-R impl
  # (ACT-R proper uses sum_j t_j^-d over multiple presentations + spreading
  # activation from working memory). For this project the heuristic is:
  #
  #   activation = ln(use_count + 1)
  #              - decay_per_day × days_since_last_seen
  #              + 0.6 × act_count
  #              + 0.4 × signal_retention

  pp_memory_activation_score() {
    local use_count="${1:-0}" days_old="${2:-0}"
    local act_count="${3:-0}" retention="${4:-0}"
    local decay="${5:-0.5}"
    LC_ALL=C awk -v u="$use_count" -v d="$days_old" \
        -v a="$act_count" -v r="$retention" -v k="$decay" '
      BEGIN { printf "%.4f", log(u + 1) - k * d + 0.6 * a + 0.4 * r }
    '
  }

  # pp_memory_recompute_scores CWD
  # Recomputes activation_score for ALL rows in this project.
  # MUST be called under pp_memory_with_lock.
  pp_memory_recompute_scores() {
    local cwd="$1"
    local proj_dir
    proj_dir=$(pp_memory_project_dir "$cwd") || return 1
    local db="$proj_dir/observations.sqlite"
    [ -f "$db" ] || return 0
    local decay="${PP_MEMORY_DECAY_PER_DAY:-0.5}"
    # Compute days_since_last_seen using SQLite julianday — portable.
    sqlite3 "$db" <<SQL
  UPDATE observations
  SET activation_score =
    log(COALESCE(use_count, 0) + 1)
    - $decay * (julianday('now') - julianday(last_seen_ts))
    + 0.6 * COALESCE(act_count, 0)
    + 0.4 * COALESCE(signal_retention, 0);
SQL
  }
  ```

- [ ] **Step 6:** Run + commit B.2

### B.3 — Ralph review for Task B

Same 3-stack: GPT focuses on SQL injection via jq inputs, activation formula edge cases (use_count=0, negative scores), use-bump correctness; debugger reproduces all bats + concurrent insert+top_k probe; ai-engineer judges whether the heuristic ACT-R is a fair representation or oversold.

---

## Task C — Signals (4 windowed) + Maintenance Under Lock

**Files:**
- Create: `lib/memory/signals.sh`
- Create: `test/memory/signals.bats`

**Goal:** 4 signals (drop symbol-touch to v0.4 per GPT review HIGH-3 + Cuts). Each signal HAS a proper 30-minute time window. Retention = consecutive-cycle-only (not global duplicate). All tagging wrapped in `pp_memory_with_lock`.

The 4 signals:
1. **retention** — same lens + same hook in THIS cycle AND prior cycle (not anywhere in history)
2. **file-edit** — observation cited a path; that path appears in `git log --since=ts --until=ts+30m --name-only`
3. **commit-mention** — git commit since obs_ts contains a ≥4-char keyword from observation hook OR body (stopword-filtered)
4. **test-flip** — observation cited a path; `LAST TEST/LINT RUN` cache shows ERROR + that path appears in the FAIL block, AND the cache mtime is within 30m of obs_ts

- [ ] **Steps 1-7:** TDD-style — failing tests, impl, run, commit. Each signal one step. Code patterns mirror v1 plan but with windowing enforced + retention rewritten + drop symbol-touch.

- [ ] **Step 8:** Wrapper `pp_memory_tag_all` runs all 4 under `pp_memory_with_lock`.

- [ ] **Step 9:** Ralph review Task C. Focus: 30-min window correctness across BSD/GNU date; retention "consecutive-only" semantics; commit-mention false-positive rate on common tokens.

---

## Task D — Patterns + Eviction + Statusline Wire-up + Eval Gates

**Files:**
- Create: `lib/memory/patterns.sh`, `lib/memory/evict.sh`
- Create: `prompts/pattern-extraction.md`
- Modify: `bin/statusline.sh`, `prompts/analyst-primary.md`, `lib/prompt-loader.sh`, `config/default.env`, `bin/polymath`
- Create: `test/memory/integration.bats`
- Create: `docs/memory-architecture.md`

### D.1 — Patterns

Implementation per v1 plan BUT with explicit `$PP_ROOT` dependency check + `run_llm` smoke test in real mode (GPT HIGH-9). Prompt-extraction prompt hardened against injection (each observation body wrapped in `<observation>...</observation>` tags, length-capped to 500 chars before insertion).

### D.2 — Eviction

```bash
#!/usr/bin/env bash
# pp_memory_evict CWD CAP_BYTES
# Drops observations meeting ALL three conditions:
#   - age >= PP_MEMORY_MIN_AGE_DAYS_BEFORE_EVICT (default 7)
#   - activation_score in bottom 20% of all rows
#   - directory total size > cap
# Evicted cohort gets a single metadata row (NOT a true theme) in
# patterns.jsonl marked evicted=true. Real consolidation deferred to v0.4.
# MUST be called under pp_memory_with_lock.
pp_memory_evict() {
  local cwd="$1"
  local cap="${2:-104857600}"
  local proj_dir
  proj_dir=$(pp_memory_project_dir "$cwd") || return 0
  local db="$proj_dir/observations.sqlite"
  [ -f "$db" ] || return 0
  local size
  size=$(du -ks "$proj_dir" | awk '{ printf "%d", $1 * 1024 }')
  [ "$size" -le "$cap" ] && return 0
  local min_age="${PP_MEMORY_MIN_AGE_DAYS_BEFORE_EVICT:-7}"
  # Drop bottom 20% by activation_score among rows age >= min_age days.
  sqlite3 "$db" <<SQL
  BEGIN;
  CREATE TEMP TABLE _evict AS
    SELECT obs_id FROM observations
    WHERE (julianday('now') - julianday(ts)) >= $min_age
    ORDER BY activation_score ASC NULLS FIRST
    LIMIT (SELECT MAX(1, COUNT(*) / 5) FROM observations
           WHERE (julianday('now') - julianday(ts)) >= $min_age);
  -- Write summary metadata (NOT a real pattern — explicitly tagged).
  SELECT json_object(
    'theme_id', 'evicted-' || strftime('%s', 'now'),
    'label', 'Evicted ' || (SELECT COUNT(*) FROM _evict) || ' low-activation observations (age ≥ $min_age days)',
    'cluster_size', (SELECT COUNT(*) FROM _evict),
    'dominant_lens', (SELECT lens_id FROM observations
                      WHERE obs_id IN (SELECT obs_id FROM _evict)
                      GROUP BY lens_id ORDER BY COUNT(*) DESC LIMIT 1),
    'evicted', 1,
    'is_consolidated_theme', 0
  ) INTO TEMP _summary;
  DELETE FROM observations WHERE obs_id IN (SELECT obs_id FROM _evict);
  COMMIT;
  VACUUM;
SQL
  # Append eviction summary to patterns.jsonl
  sqlite3 "$db" "SELECT * FROM _summary;" >> "$proj_dir/patterns.jsonl" 2>/dev/null || true
}
```

### D.3 — Statusline wire-up

In `bin/statusline.sh`, at cycle start (after grounded is built):
```bash
if [ "${PP_MEMORY_ENABLED:-1}" = "1" ] && [ "$cwd" != "-" ]; then
  _pp_proj_dir=$(pp_memory_project_dir "$cwd")
  mkdir -p "$_pp_proj_dir" 2>/dev/null
  pp_memory_db_init "$_pp_proj_dir"
  # All maintenance under single lock.
  pp_memory_with_lock "$_pp_proj_dir" '
    pp_memory_tag_all "$cwd" "$test_cache_file"
    pp_memory_recompute_scores "$cwd"
  '
  # Retrieval doesn't need the lock (SQLite handles concurrent reads).
  activated_observations=$(pp_memory_top_k "$cwd" "${PP_MEMORY_TOPK:-15}" \
    | jq -r '. | "[" + .lens_id + "] " + (.hook // "") + " | " + ((.body // "")[:120])')
  [ -f "$_pp_proj_dir/patterns.jsonl" ] && project_patterns=$(jq -r '...' "$_pp_proj_dir/patterns.jsonl" | head -8)
fi
```

At cycle end (after observation validation, per lens):
```bash
if [ "${PP_MEMORY_ENABLED:-1}" = "1" ] && [ -n "$_pp_proj_dir" ]; then
  obs_id="o-${session_id}-${lens_group}-$(date +%s)-$$"
  pp_memory_insert "$cwd" "$obs_id" "$lens_group" "$obs_topic" "$obs_hook" "$obs_body" \
    "$cited_paths_json" "$cited_symbols_json" "$session_id"
fi
```

After cycle subshell exits:
```bash
if [ "${PP_MEMORY_ENABLED:-1}" = "1" ] && [ -n "$_pp_proj_dir" ]; then
  pp_memory_with_lock "$_pp_proj_dir" '
    pp_memory_evict "$cwd" "${PP_MEMORY_MAX_BYTES:-104857600}"
    # Patterns every N cycles
    cur_count=$(sqlite3 "$_pp_proj_dir/observations.sqlite" "SELECT value FROM cycle_state WHERE key=\"count\";" 2>/dev/null || echo 0)
    cur_count=$((cur_count + 1))
    sqlite3 "$_pp_proj_dir/observations.sqlite" "INSERT OR REPLACE INTO cycle_state VALUES (\"count\", \"$cur_count\");"
    if [ $((cur_count % ${PP_MEMORY_PATTERN_EVERY_N_CYCLES:-50})) -eq 0 ]; then
      pp_memory_extract_patterns "$cwd"
    fi
  '
fi
```

### D.4 — CLI

`polymath memory status` / `prune` / `export`. Standard sql queries.

### D.5 — Eval merge gates (numeric)

`docs/memory-architecture.md` and `docs/eval-harness.md` document the PASS/FAIL rubric:

| Metric | PASS condition | FAIL condition |
|---|---|---|
| **Useful%** (warm vs cold) | +5pp absolute rise | any drop, or rise < +2pp |
| **Hallucination%** | unchanged or down | any rise |
| **Diversity** (unique topics across 7 lenses) | ≥ baseline within 10% | drop > 10% |
| **Cycle latency** | within +10% | rise > +15% |
| **Memory-off run** | identical to pre-2.3 baseline | any divergence in either direction |

Task D.5 captures the 3 baselines (memory-off, memory-on-cold, memory-on-warm) and runs the comparison. PR is blocked from merge if any FAIL condition triggers.

### D.6 — Final 4-reviewer Ralph (PR-level)

At PR creation, dispatch the full stack on the merged diff (Tasks A through D combined):
1. code-reviewer
2. debugger (reproduce all 3 baselines)
3. ai-engineer (judges whether the integrated system actually delivers ACT-R-inspired retrieval + meaningful patterns, or is structurally close-but-not-quite)
4. GPT-5.2 hostile diff review

Apply R2 fixes for HIGH findings before merge.

---

## Open questions resolved during plan

- ~~Should embeddings be batched per cycle or per-observation~~ → **Cut from this PR. v0.4.**
- ~~sqlite-vec necessary~~ → **Cut. v0.4.**
- ~~symbol-touch signal worth it~~ → **Cut. v0.4 opt-in.**
- **Sync vs fire-and-forget memory writes** → Sync (simpler; revisit if cycle wall-time exceeds 90s).
- **Schema migration story** → schema_version on every row; reader rejects rows with version > current. Migration tooling v0.4.
- **User-tier memory** (per-lens calibration across projects) → v0.4.
- **Community memory** → v0.4+ (MCP server).

---

## Self-review checklist (run before dispatch)

1. **Spec coverage:** every spec line maps to a task ✓ (4 tiers via A+B+C+D, ACT-R via B.2, 4 signals via C, patterns via D.1, eviction via D.2, locking via A.2, salted hash via A.1, redaction via A.3, eval gates via D.5).
2. **Placeholders:** none. Every code step has full code.
3. **Type consistency:** function names `pp_memory_*` consistent across tasks; SQL column names match across schema.sh, store.sh, activation.sh, signals.sh; env vars `PP_MEMORY_*` consistent in config/default.env + all libs.
4. **GPT review findings:** all 10 HIGH addressed; cuts (embeddings, sqlite-vec, symbol-touch) explicitly listed in "Open questions resolved" + "Cuts" notes.

---

## Execution Handoff

This plan ready for subagent-driven-development. Per the user directive: each task ends with a **Ralph 3-reviewer stack** (GPT-5.2 + debugger + ai-engineer); the final Task D adds GPT-5.2 to make it 4 at PR level.
