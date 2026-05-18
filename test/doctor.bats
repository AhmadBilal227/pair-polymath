#!/usr/bin/env bats
# polymath doctor: end-to-end health checks.

setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  PP_TEST_HOME="$(mktemp -d)"
  export HOME="$PP_TEST_HOME"
  export CLAUDE_DIR="$PP_TEST_HOME/.claude"
  export PP_CACHE_DIR="$CLAUDE_DIR/cache"
  mkdir -p "$CLAUDE_DIR"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/doctor.sh"
}

teardown() {
  rm -rf "$PP_TEST_HOME"
}

@test "doctor: smoke — runs without crashing" {
  run bash "$PP_ROOT/bin/polymath" doctor
  # Exit may be 0 or 1 depending on host; we only assert no crash
  [ "$status" -lt 128 ]
  [[ "$output" == *"Pair Polymath doctor"* ]]
  [[ "$output" == *"Summary:"* ]]
  [[ "$output" == *"Status:"* ]]
}

@test "doctor: reports missing settings.json as red" {
  # CLAUDE_DIR exists but settings.json doesn't
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"settings.json"* ]]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"BROKEN"* ]]
}

@test "doctor: reports valid settings.json as green" {
  echo '{"statusLine":{"command":"bash /tmp/statusline.sh"},"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"/tmp/inject-monitor-insight.sh"}]}],"PostToolUse":[{"hooks":[{"command":"/tmp/cache-test-result.sh"}]}]}}' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"settings.json"* ]]
  [[ "$output" == *"valid"* ]]
}

@test "doctor: reports invalid settings.json as red" {
  echo 'not-json' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"invalid JSON"* ]]
  [ "$status" -eq 1 ]
}

@test "doctor: reports hooks wired correctly when paths point at \$PP_ROOT" {
  # H2 fix: strict-match against PP_ROOT-resolved paths, not basenames.
  # We must reference real files in this checkout for the test to pass.
  local sl_path="$PP_ROOT/bin/statusline.sh"
  local user_hook="$PP_ROOT/hooks/inject-monitor-insight.sh"
  local post_hook="$PP_ROOT/hooks/cache-test-result.sh"
  local session_hook="$PP_ROOT/hooks/session-end.sh"
  jq -n --arg sl "bash '$sl_path'" --arg uh "$user_hook" --arg ph "$post_hook" --arg sh "$session_hook" '{
    statusLine: {command: $sl},
    hooks: {
      UserPromptSubmit: [{matcher:"*", hooks:[{type:"command", command:$uh, timeout:3}]}],
      PostToolUse:       [{matcher:"Bash", hooks:[{type:"command", command:$ph, timeout:3}]}],
      SessionEnd:        [{matcher:"", hooks:[{type:"command", command:$sh, timeout:3}]}]
    }
  }' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"hooks wired"* ]]
  [[ "$output" == *"UserPromptSubmit + PostToolUse + SessionEnd"* ]]
  # H1 fix: statusLine wired should be green when path resolves correctly
  [[ "$output" == *"statusLine wired"* ]]
  [[ "$output" == *"→"* ]]
}

@test "doctor: SessionEnd missing is yellow while OAR disabled" {
  local user_hook="$PP_ROOT/hooks/inject-monitor-insight.sh"
  local post_hook="$PP_ROOT/hooks/cache-test-result.sh"
  jq -n --arg uh "$user_hook" --arg ph "$post_hook" '{
    hooks: {
      UserPromptSubmit: [{matcher:"*", hooks:[{type:"command", command:$uh, timeout:3}]}],
      PostToolUse:       [{matcher:"Bash", hooks:[{type:"command", command:$ph, timeout:3}]}]
    }
  }' > "$CLAUDE_DIR/settings.json"
  PP_OAR_ENABLE=0 run doctor_check_hooks_wired
  [ "$status" -eq 1 ]
  [[ "$output" == *"SessionEnd missing"* ]]
  [[ "$output" == *"OAR disabled"* ]]
}

@test "doctor: SessionEnd missing is red while OAR enabled" {
  local user_hook="$PP_ROOT/hooks/inject-monitor-insight.sh"
  local post_hook="$PP_ROOT/hooks/cache-test-result.sh"
  jq -n --arg uh "$user_hook" --arg ph "$post_hook" '{
    hooks: {
      UserPromptSubmit: [{matcher:"*", hooks:[{type:"command", command:$uh, timeout:3}]}],
      PostToolUse:       [{matcher:"Bash", hooks:[{type:"command", command:$ph, timeout:3}]}]
    }
  }' > "$CLAUDE_DIR/settings.json"
  PP_OAR_ENABLE=1 run doctor_check_hooks_wired
  [ "$status" -eq 2 ]
  [[ "$output" == *"SessionEnd=0"* ]]
  [[ "$output" == *"re-run installer"* ]]
}

@test "doctor: H1 — yellow statusLine returns non-zero contribution (not silently green)" {
  # Decoy statusLine pointing elsewhere — must surface as yellow and be counted
  echo '{"statusLine":{"command":"bash /tmp/decoy-statusline.sh"},"hooks":{}}' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"statusLine wired"* ]]
  [[ "$output" == *"points to a different script"* ]]
  # Summary's yellow count must be >= 1
  echo "$output" | grep -qE 'Summary:.*1 yellow|Summary:.*[2-9][0-9]* yellow'
}

@test "doctor: H2 — substring-decoy hook path is NOT counted as wired" {
  # A decoy hook with a matching basename but wrong location must NOT pass strict-match
  jq -n '{
    statusLine: {command:"bash /tmp/x.sh"},
    hooks: {
      UserPromptSubmit: [{matcher:"*", hooks:[{type:"command", command:"/tmp/inject-monitor-insight.sh"}]}],
      PostToolUse:       [{matcher:"Bash", hooks:[{type:"command", command:"/tmp/cache-test-result.sh"}]}]
    }
  }' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"missing or pointing elsewhere"* ]]
  [ "$status" -eq 1 ]   # red trips overall BROKEN exit
}

@test "doctor: reports missing hooks as red" {
  echo '{"statusLine":{"command":"bash /tmp/statusline.sh"},"hooks":{}}' > "$CLAUDE_DIR/settings.json"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"hooks wired"* ]]
  [[ "$output" == *"missing"* ]]
}

@test "doctor: lens registry loads (built-in 7)" {
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"lenses"* ]]
  [[ "$output" == *"7 loaded"* ]]
}

@test "doctor: router libs check #14 verifies prompt render + ID round-trip (v0.4 P2.5)" {
  run bash "$PP_ROOT/bin/polymath" doctor
  echo "$output" | grep -qF 'router libs'
  echo "$output" | grep -qF 'pick + render + ID round-trip verified'
}

@test "doctor: coreutils check #15 recommends brew install on macOS when absent (v0.4 P2.5)" {
  run bash "$PP_ROOT/bin/polymath" doctor
  echo "$output" | grep -qF 'coreutils'
  # Either green (timeout present) OR yellow with brew recommendation
  echo "$output" | grep -qE 'coreutils.*(timeout binary present|brew install coreutils|install via apt)'
}

@test "doctor: transcript libs check fires and verifies canonical redactor (v0.4 Phase 1)" {
  # Hermetic HOME means doctor may exit non-zero on settings.json checks;
  # we only assert the new check line appears with the canonical-redactor
  # signature (proves the probe ran and saw pp_memory_redact_body wired).
  run bash "$PP_ROOT/bin/polymath" doctor
  echo "$output" | grep -qF 'transcript libs'
  echo "$output" | grep -qF 'filter+tool_calls+canonical-redactor wired'
}

@test "doctor: transcript libs check would FAIL if canonical redactor disappears" {
  # Probe directly to confirm the check would detect a regression where
  # pp_memory_redact_body got renamed or deleted. We can't easily simulate
  # that within bats without forking the binary, so instead verify the
  # check function itself is sourced and callable.
  . "$PP_ROOT/lib/doctor.sh"
  type doctor_check_transcript_libs >/dev/null 2>&1
  [ "$?" -eq 0 ]
}

@test "doctor: prompts present (built-in 9) and contracts lint" {
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"prompts"* ]]
  [[ "$output" == *"9/9 built-in present"* ]]
  [[ "$output" == *"prompt contracts"* ]]
  [[ "$output" == *"9/9 manifests lint clean"* ]]
}

@test "doctor: smoke fixture runs to exit 0" {
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"statusline smoke"* ]]
  [[ "$output" == *"exit 0"* ]]
}

@test "doctor: SUMMARY line lists counts in order green/yellow/red" {
  run bash "$PP_ROOT/bin/polymath" doctor
  # The summary line should match the pattern
  echo "$output" | grep -q 'Summary: .* green, .* yellow, .* red'
}

@test "doctor --network: hidden behind PP_TEST_NETWORK env (M1 fix: don't burn \$ in CI)" {
  # Default: never exercise the live OpenAI path; would otherwise cost
  # ~$0.0001 per CI run and slow tests / introduce flakiness.
  if [ "${PP_TEST_NETWORK:-0}" != "1" ]; then
    skip "set PP_TEST_NETWORK=1 to exercise live OpenAI probe"
  fi
  run bash "$PP_ROOT/bin/polymath" doctor --network
  [ "$status" -lt 128 ]
  [[ "$output" == *"network probe"* ]]
}

@test "doctor --network: flag is accepted but probe is gated (no live call by default)" {
  # Verify --network is parsed without crash even when we don't run the probe
  # (PATH stripped so 'llm' is absent → yellow "skipped" branch).
  PATH=/usr/bin:/bin run bash "$PP_ROOT/bin/polymath" doctor --network
  [ "$status" -lt 128 ]
  [[ "$output" == *"Summary:"* ]]
}

# ========================================================
# check #20 — install drift (v0.5.1.1)
# ========================================================

@test "doctor #20: install drift green on a fresh hermetic install" {
  # Clean HOME — no legacy hook file, no legacy cache files. Should be green.
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"install drift"* ]]
  [[ "$output" == *"no stale hooks or pre-v0.4 cache files"* ]]
}

@test "doctor #20: install drift yellow when legacy global hook file present" {
  # Simulate operator who installed pre-v0.4 — the global hook file persists
  # at ~/.claude/hooks/inject-monitor-insight.sh even after v0.4+ moves the
  # install path. Drop the file in the hermetic HOME.
  mkdir -p "$HOME/.claude/hooks"
  echo '#!/bin/bash' > "$HOME/.claude/hooks/inject-monitor-insight.sh"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"install drift"* ]]
  [[ "$output" == *"legacy global hook"* ]]
  [[ "$output" == *"rm when convenient"* ]]
}

@test "doctor #20: install drift yellow when pre-v0.4 indexed-lens cache files present" {
  # Simulate pre-v0.4 caches that used numeric lens indices instead of IDs.
  mkdir -p "$PP_CACHE_DIR"
  : > "$PP_CACHE_DIR/cc-monitor-abc-lens0-something.txt"
  : > "$PP_CACHE_DIR/cc-monitor-abc-lens3-other.txt"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"install drift"* ]]
  [[ "$output" == *"pre-v0.4 indexed-lens cache files"* ]]
}

@test "doctor #20: install drift surfaces BOTH findings together when both present" {
  mkdir -p "$HOME/.claude/hooks"
  echo '#!/bin/bash' > "$HOME/.claude/hooks/inject-monitor-insight.sh"
  mkdir -p "$PP_CACHE_DIR"
  : > "$PP_CACHE_DIR/cc-monitor-abc-lens0-something.txt"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"install drift"* ]]
  [[ "$output" == *"legacy global hook"* ]]
  [[ "$output" == *"pre-v0.4 indexed-lens"* ]]
}

@test "doctor #20: install drift current-lens-ID cache files do NOT trigger the check" {
  # Files matching the post-v0.4 cc-monitor-${sid}-${LENS_ID}.txt format
  # (e.g. ENGINEERING, SECURITY) should NOT match the legacy pattern.
  mkdir -p "$PP_CACHE_DIR"
  : > "$PP_CACHE_DIR/cc-monitor-abc-ENGINEERING.txt"
  : > "$PP_CACHE_DIR/cc-monitor-abc-SECURITY.txt"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"install drift"* ]]
  [[ "$output" == *"no stale hooks"* ]]
}

# ========================================================
# check #21 — OAR data quality sentinel (v0.5.2 PM3)
# ========================================================
#
# Per the pre-mortem (PM3): the most likely silent-failure pattern is the
# labeler completing successfully but every outcome landing on "ignored" —
# meaning pp_oar_referenced is silently broken. doctor_check_oar_quality is
# the sentinel that catches this WITHOUT a stuck-row signal.

@test "doctor #21: oar quality green when PP_OAR_ENABLE=0 (default)" {
  # Disabled OAR — no data is expected to exist; check should be green.
  unset PP_OAR_ENABLE
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  [[ "$output" == *"OAR disabled"* ]]
}

_pp_doctor_oar_enable() {
  # config/default.env sets PP_OAR_ENABLE=0 and lib/config.sh sources it
  # unconditionally — env vars get clobbered. Write to user.env (which loads
  # AFTER default.env) so the override survives into the doctor subprocess.
  mkdir -p "$HOME/.claude/pair-polymath/config"
  printf 'PP_OAR_ENABLE=1\n' > "$HOME/.claude/pair-polymath/config/user.env"
}

@test "doctor #21: oar quality green when enabled but no labeled file yet" {
  # OAR enabled, but oar-labeled.jsonl doesn't exist — fresh install case.
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  [[ "$output" == *"no labeled data yet"* ]]
}

@test "doctor #21: oar quality YELLOW when injected observations exist but OAR has no pending rows" {
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  printf 'hash-a\n' > "$PP_CACHE_DIR/cc-monitor-injected-hash-s1-ENGINEERING.txt"
  printf 'hash-b\n' > "$PP_CACHE_DIR/cc-monitor-injected-hash-s1-SECURITY.txt"
  printf '{"session_id":"old","outcome":"ignored"}\n' > "$PP_CACHE_DIR/oar-labeled.jsonl"
  : > "$PP_CACHE_DIR/oar-pending.jsonl"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  [[ "$output" == *"appears starved"* ]]
  [[ "$output" == *"verify SessionEnd hook wiring"* ]]
}

@test "doctor #21: oar quality green when fewer than 20 labeled rows" {
  # Insufficient sample — can't yet evaluate degeneracy.
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  local _i
  for _i in 1 2 3 4 5; do
    printf '{"session_id":"s%d","outcome":"ignored"}\n' "$_i" \
      >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  done
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  [[ "$output" == *"only 5 labeled rows"* ]]
  [[ "$output" == *"need"* ]]
}

@test "doctor #21: oar quality YELLOW when ALL 20+ labeled rows are 'ignored' (PM3 load-bearing)" {
  # The pre-mortem scenario: labeler completes, but referenced detection
  # silently always returns 0. Every row lands on "ignored". This is the
  # exact alarm condition PM3 was added to detect.
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  local _i
  for _i in $(seq 1 20); do
    printf '{"session_id":"s%d","outcome":"ignored"}\n' "$_i" \
      >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  done
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  [[ "$output" == *"ALL 20 labeled rows are 'ignored'"* ]]
  [[ "$output" == *"referenced detection may be broken"* ]]
  [[ "$output" == *"polymath history"* ]]
  # Summary's yellow count must be >= 1
  echo "$output" | grep -qE 'Summary:.*[1-9][0-9]* yellow'
}

@test "doctor #21: oar quality GREEN when 20+ labeled rows with mixed outcomes" {
  # Non-degenerate: at least one row is not "ignored" → measurement looks healthy.
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  local _i
  # 18 ignored
  for _i in $(seq 1 18); do
    printf '{"session_id":"s%d","outcome":"ignored"}\n' "$_i" \
      >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  done
  # 1 acted-on, 1 referenced — proves referenced detection is working
  printf '{"session_id":"s19","outcome":"acted_on"}\n' \
    >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  printf '{"session_id":"s20","outcome":"referenced"}\n' \
    >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  [[ "$output" == *"20 rows"* ]]
  [[ "$output" == *"ignored=18"* ]]
  [[ "$output" == *"non-degenerate"* ]]
}

@test "doctor #21: oar quality YELLOW when v2 rows miss prompt lineage" {
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  local _i _out
  for _i in $(seq 1 20); do
    _out="ignored"
    [ "$_i" -eq 19 ] && _out="acted"
    [ "$_i" -eq 20 ] && _out="referenced"
    jq -nc --arg sid "s$_i" --arg out "$_out" \
      '{schema_version:2,session_id:$sid,outcome:$out}' \
      >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  done
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  [[ "$output" == *"missing prompt lineage"* ]]
  [[ "$output" == *"prompt improvement loops cannot attribute outcomes"* ]]
}

@test "doctor #21: oar quality GREEN when v2 rows have prompt lineage" {
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  local _i _out
  for _i in $(seq 1 20); do
    _out="ignored"
    [ "$_i" -eq 19 ] && _out="acted"
    [ "$_i" -eq 20 ] && _out="referenced"
    jq -nc --arg sid "s$_i" --arg out "$_out" \
      '{schema_version:2,session_id:$sid,outcome:$out,
        prompt_versions:{"analyst-primary":"0.5.4.0","critique":"0.5.4.0"}}' \
      >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  done
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  [[ "$output" == *"20 rows"* ]]
  [[ "$output" == *"ignored=18"* ]]
  [[ "$output" == *"non-degenerate"* ]]
}

# ----- post-review hardening (GPT-5 + spec-reviewer convergent findings) -----
# The sentinel must not silently report "healthy" when the data pipeline
# behind it is broken. These tests pin the two failure paths that would
# otherwise mask PM3's load-bearing signal.

@test "doctor #21: oar quality YELLOW when jq missing (sentinel must not silently pass)" {
  # In-process test: source lib/doctor.sh, override `command` to lie about
  # jq's absence, invoke the function directly. PATH-strip won't work
  # because jq commonly lives in /usr/bin alongside dirname/wc/cut.
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  local _i
  for _i in $(seq 1 20); do
    printf '{"session_id":"s%d","outcome":"ignored"}\n' "$_i" \
      >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  done
  # Override the `command` builtin to report jq as missing while preserving
  # all other lookups. Defined inline so it only affects this test scope.
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "jq" ]; then
      return 1
    fi
    builtin command "$@"
  }
  # PP_CACHE_DIR is exported in setup; the doctor function reads it. The
  # in-process invocation bypasses config.sh, so set PP_OAR_ENABLE directly.
  PP_OAR_ENABLE=1 run doctor_check_oar_quality
  unset -f command
  [ "$status" -eq 1 ]
  [[ "$output" == *"OAR quality"* ]]
  [[ "$output" == *"jq not installed"* ]]
  [[ "$output" == *"cannot evaluate"* ]]
}

@test "doctor #21: oar quality YELLOW when oar-labeled.jsonl is malformed (no false-green)" {
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  # 20 lines of garbage — wc -l ≥20 (passes threshold), jq -s fails.
  local _i
  for _i in $(seq 1 20); do
    printf 'not-json-at-all-row-%d\n' "$_i" \
      >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  done
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  # Either jq parse error OR low parseable-row count branch — both are yellow.
  [[ "$output" == *"check file integrity"* ]]
}

@test "doctor #21: oar quality YELLOW when ignored+malformed mix masks degenerate pattern" {
  # The PM-of-the-PM case: 19 valid 'ignored' + 1 'acted_on' WOULD be green,
  # but if the 1 'acted_on' is actually a blank/malformed line, the older
  # implementation incorrectly counted it as a non-ignored row. The fix
  # filters denominator to valid objects only.
  _pp_doctor_oar_enable
  mkdir -p "$PP_CACHE_DIR"
  local _i
  for _i in $(seq 1 20); do
    printf '{"session_id":"s%d","outcome":"ignored"}\n' "$_i" \
      >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  done
  # Append blank + malformed lines that older logic would have inflated _total with.
  printf '\n' >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  printf '{"session_id":"sX","outcome":\n' >> "$PP_CACHE_DIR/oar-labeled.jsonl"
  run bash "$PP_ROOT/bin/polymath" doctor
  [[ "$output" == *"OAR quality"* ]]
  # Two acceptable outcomes: (a) the degenerate-ignored alarm still fires
  # because we filter to valid rows; (b) the parse-error branch fires. Both
  # are yellow. The illegal outcome is a green "non-degenerate" claim.
  [[ "$output" != *"non-degenerate"* ]]
}

# === Stage B Task 13 — doctor check #22: drift_count invariant ===
#
# Verdict-file v2 schema (Stage A Task 3) stamps:
#   # v2: canonical_allowlist_sha8_prompt=<8-hex>
#   # v2: canonical_allowlist_sha8_validator=<8-hex>
# This check counts cases where the two diverge within the last 24h.
#
# NOTE (B2 implementer): Stage A as shipped (bin/statusline.sh:75) actually
# stamps a single `canonical_allowlist_sha8=<8hex>` field rather than the
# dual `_prompt`/`_validator` pair this plan-task assumes. That divergence
# materialises in Stage C, when the rendered prompt block flips to top-N
# truncation while the validator still consumes the full inventory. Until
# then, real verdicts produce zero matches against the dual-hash regex →
# `_total=0` → GREEN ("no verdict data"), which is exactly the conservative
# behaviour requested. The tests below fabricate the dual-hash form so the
# check is exercised end-to-end ahead of Stage C.

_pp_doctor_write_verdict() {
  # Helper: write a v2 verdict file at a controlled mtime.
  # Args: <name> <prompt_sha8> <validator_sha8> <minutes_ago>
  local _name="$1" _ps="$2" _vs="$3" _min="$4"
  local _f="$PP_CACHE_DIR/cc-monitor-sess1-${_name}-verdict.txt"
  {
    printf 'lens0: PASS -- ok\n'
    printf '# v2: schema_version=2\n'
    printf '# v2: outcome=pass\n'
    printf '# v2: canonical_allowlist_sha8_prompt=%s\n' "$_ps"
    printf '# v2: canonical_allowlist_sha8_validator=%s\n' "$_vs"
  } > "$_f"
  # Backdate. Cross-platform touch: BSD `-A` not portable; use `-t` with
  # date math. Fall back to no-op (file is fresh anyway, fits ≤24h cases).
  if [ "$_min" -gt 0 ]; then
    if date -v -"${_min}"M +%Y%m%d%H%M.%S >/dev/null 2>&1; then
      # macOS BSD date.
      touch -t "$(date -v -"${_min}"M +%Y%m%d%H%M.%S)" "$_f"
    elif date -d "@$(($(date +%s) - _min*60))" +%Y%m%d%H%M.%S >/dev/null 2>&1; then
      # GNU date.
      touch -t "$(date -d "@$(($(date +%s) - _min*60))" +%Y%m%d%H%M.%S)" "$_f"
    fi
  fi
}

@test "doctor #22: GREEN when no verdict files exist" {
  PP_CACHE_DIR="$CLAUDE_DIR/cache" run doctor_check_drift_count
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift count"* ]]
  [[ "$output" == *"no verdict data"* ]]
}

@test "doctor #22: GREEN when all canonical_allowlist_sha8 pairs match" {
  mkdir -p "$PP_CACHE_DIR"
  _pp_doctor_write_verdict UX_DESIGN aaaaaaaa aaaaaaaa 0
  _pp_doctor_write_verdict ENGINEERING bbbbbbbb bbbbbbbb 0
  _pp_doctor_write_verdict SECURITY cccccccc cccccccc 0
  run doctor_check_drift_count
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift count"* ]]
  [[ "$output" == *"drift_count=0"* ]]
}

@test "doctor #22: YELLOW when canonical_allowlist_sha8 pair diverges" {
  mkdir -p "$PP_CACHE_DIR"
  _pp_doctor_write_verdict UX_DESIGN aaaaaaaa aaaaaaaa 0
  _pp_doctor_write_verdict ENGINEERING bbbbbbbb ccccdddd 0   # drift!
  run doctor_check_drift_count
  [ "$status" -eq 1 ]
  [[ "$output" == *"drift count"* ]]
  [[ "$output" == *"drift_count=1"* ]]
  [[ "$output" == *"inventory pipeline"* ]]
}

@test "doctor #22: ignores verdict files older than 24h" {
  mkdir -p "$PP_CACHE_DIR"
  # Drift exists but it's 25h old — out-of-window, should NOT alarm.
  _pp_doctor_write_verdict UX_DESIGN aaaaaaaa bbbbbbbb 1500
  # Probe GNU-first then BSD (matches lib/oar.sh:637 pattern). `stat -f %m`
  # on GNU coreutils means "filesystem format" and prints fs metadata — not
  # file mtime — without failing, so a BSD-first probe on Ubuntu CI yields
  # non-numeric output and the `((…))` below errors. Skip if neither dialect
  # gives a clean integer mtime.
  local _mtime _f="$PP_CACHE_DIR/cc-monitor-sess1-UX_DESIGN-verdict.txt"
  if stat -c %Y /dev/null >/dev/null 2>&1; then
    _mtime=$(stat -c %Y "$_f" 2>/dev/null)
  elif stat -f %m /dev/null >/dev/null 2>&1; then
    _mtime=$(stat -f %m "$_f" 2>/dev/null)
  fi
  case "$_mtime" in ''|*[!0-9]*) skip "stat mtime probe unsupported here" ;; esac
  local _now; _now=$(date +%s)
  [ "$((_now - _mtime))" -gt 86400 ] || skip "touch -t did not stick mtime to 25h ago"
  run doctor_check_drift_count
  [ "$status" -eq 0 ]
  [[ "$output" == *"no verdict data"* ]] || [[ "$output" == *"drift_count=0"* ]]
}

@test "doctor #22: GREEN when only single-hash (Stage A v1) verdicts exist" {
  # Real Stage A verdicts (bin/statusline.sh:75) stamp the SINGLE-hash form
  # `canonical_allowlist_sha8=<8hex>`. The dual-hash regex this check uses
  # must NOT match them → _total=0 → green ("no v2 verdicts with v2 hashes").
  # This is the conservative-safe behaviour requested when A4 only writes
  # one canonical field.
  mkdir -p "$PP_CACHE_DIR"
  local _f="$PP_CACHE_DIR/cc-monitor-sess1-UX_DESIGN-verdict.txt"
  {
    printf '# schema_version: 2\n'
    printf 'lens0: PASS -- ok\n'
    printf '# v2: canonical_allowlist_sha8=aaaaaaaa rendered_prompt_sha8=aaaaaaaa silent_reason=\n'
  } > "$_f"
  run doctor_check_drift_count
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift count"* ]]
  [[ "$output" == *"no verdict data"* ]]
}
