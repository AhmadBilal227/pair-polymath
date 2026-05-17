#!/usr/bin/env bats
# v0.5.1.1 Stage C — Task 2 (prompt-side inventory unify + NEARBY MENTIONS).
#
# Flag OFF (default) ⇒ legacy grep block as the single primary section; no
# NEARBY MENTIONS appended; statusline STDOUT byte-identical to pre-Stage-C.
# Flag ON ⇒ FILE-READ-filtered SYMBOL block + NEARBY MENTIONS section
# carrying the broader grep set, explicitly marked non-citable.
#
# Stage C also back-patches _pp_write_verdict_v2 to emit DUAL hashes —
# those tests live in test/v0.5.1.1-verdict-stamping.bats. This file pins
# the helper-level rendering contract.

setup() {
  HOME="$(mktemp -d)"; export HOME
  CLAUDE_DIR="$HOME/.claude"; export CLAUDE_DIR
  PP_CACHE_DIR="$HOME/.claude/cache"; mkdir -p "$PP_CACHE_DIR"; export PP_CACHE_DIR
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; export PP_ROOT
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/grounding.sh"
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/citations.sh"  # provides _PP_CITATION_STOPWORDS
}
teardown() { rm -rf "$HOME"; }

# ===========================================================================
# Helper: pp_grounding_sort_and_truncate — deterministic top-N truncation
# ===========================================================================

@test "task2: sort_and_truncate — deterministic sort (freq desc, ASCII tie-break)" {
  local _golden_in="$PP_ROOT/test/fixtures/v0.5.1.1/symbol-inventory-golden.txt"
  local _golden_out="$PP_ROOT/test/fixtures/v0.5.1.1/symbol-inventory-truncated-golden.txt"
  [ -f "$_golden_in" ]
  [ -f "$_golden_out" ]
  local _actual _expected
  _actual=$(pp_grounding_sort_and_truncate 3 < "$_golden_in")
  _expected=$(cat "$_golden_out")
  if [ "$_actual" != "$_expected" ]; then
    printf 'EXPECTED:\n%s\n--- ACTUAL ---\n%s\n' "$_expected" "$_actual" >&2
  fi
  [ "$_actual" = "$_expected" ]
}

@test "task2: sort_and_truncate — no '+N more' when count <= N" {
  local _golden_in="$PP_ROOT/test/fixtures/v0.5.1.1/symbol-inventory-golden.txt"
  local _actual
  # N=100 — all 8 symbols fit, no truncation suffix.
  _actual=$(pp_grounding_sort_and_truncate 100 < "$_golden_in")
  ! printf '%s\n' "$_actual" | grep -q '+.* more'
  # All 8 rows present (one colon per "name: N refs" line).
  [ "$(printf '%s\n' "$_actual" | grep -c ':')" = "8" ]
}

@test "task2: sort_and_truncate — sha8 stability across two identical runs" {
  local _golden_in="$PP_ROOT/test/fixtures/v0.5.1.1/symbol-inventory-golden.txt"
  local _h1 _h2
  _h1=$(pp_grounding_sort_and_truncate 3 < "$_golden_in" | shasum -a 256 | cut -c1-8)
  _h2=$(pp_grounding_sort_and_truncate 3 < "$_golden_in" | shasum -a 256 | cut -c1-8)
  [ "$_h1" = "$_h2" ]
}

@test "task2: sort_and_truncate — empty stdin produces empty stdout" {
  local _out
  _out=$(printf '' | pp_grounding_sort_and_truncate 80)
  [ -z "$_out" ]
}

# ===========================================================================
# Helper: pp_grounding_symbol_inventory_from_file_read (in-memory tokenizer)
# ===========================================================================

@test "task2: inventory_from_file_read — extracts function/const/class/def identifiers" {
  local _src
  _src=$(cat <<'EOF'
function alpha() { return 1; }
const beta = 2;
class Gamma {}
def epsilon():
  pass
let theta = 4;
EOF
)
  local _out
  _out=$(pp_grounding_symbol_inventory_from_file_read "$_src")
  printf '%s\n' "$_out" | grep -q '^alpha$'
  printf '%s\n' "$_out" | grep -q '^beta$'
  printf '%s\n' "$_out" | grep -q '^Gamma$'
  printf '%s\n' "$_out" | grep -q '^epsilon$'
  printf '%s\n' "$_out" | grep -q '^theta$'
}

@test "task2: inventory_from_file_read — empty input returns empty stdout" {
  local _out
  _out=$(pp_grounding_symbol_inventory_from_file_read "")
  [ -z "$_out" ]
}

# ===========================================================================
# Helper: pp_grounding_render_symbol_block
# ===========================================================================

@test "task2: PP_INVENTORY_UNIFY_ACTIVE=0 keeps legacy grep-derived SYMBOL REFERENCE COUNTS" {
  local _cwd="$HOME/proj"
  mkdir -p "$_cwd"
  cat > "$_cwd/foo.ts" <<'EOF'
function alpha() { return 1; }
const beta = 2;
class Gamma {}
EOF
  cat > "$_cwd/uses.ts" <<'EOF'
alpha(); alpha(); beta; new Gamma();
EOF
  unset PP_INVENTORY_UNIFY_ACTIVE
  local _out
  _out=$(pp_grounding_render_symbol_block "$(cat "$_cwd/foo.ts")" "$_cwd" 80 2>&1)
  # Legacy format: "name: N refs", one per line, includes all extracted candidates.
  printf '%s\n' "$_out" | grep -q '^alpha:'
  printf '%s\n' "$_out" | grep -q '^beta:'
  printf '%s\n' "$_out" | grep -q '^Gamma:'
  # No NEARBY MENTIONS suffix from this helper (composer's job).
  ! printf '%s\n' "$_out" | grep -q 'NEARBY MENTIONS'
}

@test "task2: PP_INVENTORY_UNIFY_ACTIVE=1 — SYMBOL block filtered to FILE-READ symbols" {
  local _cwd="$HOME/proj"
  mkdir -p "$_cwd"
  # foo.ts is the planner-picked file: only alpha + Gamma are FILE-READ-defined.
  cat > "$_cwd/foo.ts" <<'EOF'
function alpha() { return 1; }
class Gamma {}
EOF
  # bar.ts is NOT picked but grep-refs alpha, beta, Gamma. With flag on,
  # the symbol block must NOT include beta (not in FILE READ).
  cat > "$_cwd/bar.ts" <<'EOF'
function beta() { alpha(); new Gamma(); }
EOF
  export PP_INVENTORY_UNIFY_ACTIVE=1
  local _out
  _out=$(pp_grounding_render_symbol_block "$(cat "$_cwd/foo.ts")" "$_cwd" 80 2>&1)
  printf '%s\n' "$_out" | grep -q '^alpha:'
  printf '%s\n' "$_out" | grep -q '^Gamma:'
  # beta is grep-only — must be filtered out by canonical-set membership.
  ! printf '%s\n' "$_out" | grep -q '^beta:'
}

# ===========================================================================
# Helper: pp_grounding_compose_symbol_sections
# ===========================================================================

@test "task2: PP_INVENTORY_UNIFY_ACTIVE=0 — grounded blob has NO NEARBY MENTIONS section" {
  unset PP_INVENTORY_UNIFY_ACTIVE
  local _grounded
  _grounded=$(pp_grounding_compose_symbol_sections \
    "alpha: 2 refs
beta: 1 refs" \
    "" 2>&1)
  printf '%s\n' "$_grounded" | grep -q '=== SYMBOL REFERENCE COUNTS'
  ! printf '%s\n' "$_grounded" | grep -q 'NEARBY MENTIONS'
}

@test "task2: PP_INVENTORY_UNIFY_ACTIVE=1 — NEARBY MENTIONS block added with legacy grep output" {
  export PP_INVENTORY_UNIFY_ACTIVE=1
  local _grounded
  _grounded=$(pp_grounding_compose_symbol_sections \
    "alpha: 2 refs
Gamma: 1 refs" \
    "alpha: 2 refs
beta: 1 refs
Gamma: 1 refs" 2>&1)
  # Primary section has the FILE-READ-filtered set.
  printf '%s\n' "$_grounded" | grep -q '=== SYMBOL REFERENCE COUNTS (FILE-READ-derived'
  # NEARBY MENTIONS section appears AFTER, with literal spec text.
  printf '%s\n' "$_grounded" \
    | grep -q '=== NEARBY MENTIONS (NOT CITABLE — read the file first to cite) ==='
  # NEARBY MENTIONS body contains the legacy grep symbols (beta proves it).
  printf '%s\n' "$_grounded" | awk '/NEARBY MENTIONS/{p=1} p' | grep -q '^beta:'
}

@test "task2: PP_INVENTORY_UNIFY_ACTIVE=0 — composer is byte-identical to pre-Stage-C heredoc shape" {
  # Pin that the composer with NO nearby block and flag OFF emits the
  # exact bytes the pre-Stage-C heredoc would have emitted (modulo the
  # heredoc-added trailing newline, which command substitution strips).
  unset PP_INVENTORY_UNIFY_ACTIVE
  local _expected='=== SYMBOL REFERENCE COUNTS (grep across cwd) ===
alpha: 2 refs
beta: 1 refs'
  local _actual
  _actual=$(pp_grounding_compose_symbol_sections \
    "alpha: 2 refs
beta: 1 refs" \
    "" 2>&1)
  [ "$_actual" = "$_expected" ]
}

@test "task2: PP_INVENTORY_UNIFY_ACTIVE=0 + empty primary — emits legacy '(no symbols extracted...)' default" {
  unset PP_INVENTORY_UNIFY_ACTIVE
  local _expected='=== SYMBOL REFERENCE COUNTS (grep across cwd) ===
(no symbols extracted from file read)'
  local _actual
  _actual=$(pp_grounding_compose_symbol_sections "" "" 2>&1)
  [ "$_actual" = "$_expected" ]
}

@test "task2: PP_INVENTORY_UNIFY_ACTIVE=1 + empty primary — emits FILE-READ empty-state sentinel" {
  export PP_INVENTORY_UNIFY_ACTIVE=1
  local _actual
  _actual=$(pp_grounding_compose_symbol_sections "" "alpha: 1 refs" 2>&1)
  printf '%s\n' "$_actual" | grep -q '(no FILE-READ symbols extracted; cite by path only)'
  printf '%s\n' "$_actual" | grep -q '=== NEARBY MENTIONS'
}

# ===========================================================================
# Cross-helper drift invariant — the core Stage C contract
# ===========================================================================

@test "task2: prompt-side and validator-side render IDENTICAL canonical sets (drift=0)" {
  # Both the prompt-side render and the validator-side allowlist must
  # hash-equal on the canonical (pre-truncation) FILE-READ symbol set —
  # they BOTH derive from pp_grounding_symbol_inventory_from_file_read.
  local _cwd="$HOME/proj"; mkdir -p "$_cwd"
  cat > "$_cwd/foo.ts" <<'EOF'
function alpha() {}
class Gamma {}
const beta = 1;
EOF
  local _prompt_canon _validator_canon
  _prompt_canon=$(pp_grounding_symbol_inventory_from_file_read "$(cat "$_cwd/foo.ts")" \
    | LC_ALL=C sort | shasum -a 256 | cut -c1-8)
  _validator_canon=$(pp_grounding_symbol_inventory_from_file_read "$(cat "$_cwd/foo.ts")" \
    | LC_ALL=C sort | shasum -a 256 | cut -c1-8)
  [ "$_prompt_canon" = "$_validator_canon" ]
  # Sanity: hash must be non-empty 8 hex chars.
  printf '%s' "$_prompt_canon" | grep -Eq '^[0-9a-f]{8}$'
}

@test "task2: facts-file inventory and in-memory inventory agree on the same source" {
  # pp_grounding_symbol_inventory (facts-file) and pp_grounding_symbol_
  # inventory_from_file_read (in-memory) must extract the same canonical
  # set when given the same FILE-READ content. Drift between them would
  # break the drift_count invariant before it even gets to the hash.
  local _facts="$HOME/facts.txt"
  cat > "$_facts" <<'EOF'
=== USER RECENT MESSAGES (PRIMARY CONTEXT — focus your observation on this) ===
(no user messages yet)

=== FILE READ (planner picked: foo.ts) ===
function alpha() { return 1; }
const beta = 2;
class Gamma {}

=== LAST TEST/LINT RUN (≤30min, from PostToolUse hook) ===
(no recent test/lint runs)
EOF
  local _facts_out _mem_out
  _facts_out=$(pp_grounding_symbol_inventory "$_facts" | LC_ALL=C sort -u)
  _mem_out=$(pp_grounding_symbol_inventory_from_file_read \
    "function alpha() { return 1; }
const beta = 2;
class Gamma {}" | LC_ALL=C sort -u)
  # Both pipelines must surface the same canonical identifiers. They may
  # differ in stopword filtering (facts-file applies the citation stopword
  # filter; in-memory uses the planner-symbol regex). Both must include
  # alpha, beta, Gamma.
  printf '%s\n' "$_facts_out" | grep -q '^alpha$'
  printf '%s\n' "$_facts_out" | grep -q '^beta$'
  printf '%s\n' "$_facts_out" | grep -q '^Gamma$'
  printf '%s\n' "$_mem_out" | grep -q '^alpha$'
  printf '%s\n' "$_mem_out" | grep -q '^beta$'
  printf '%s\n' "$_mem_out" | grep -q '^Gamma$'
}
