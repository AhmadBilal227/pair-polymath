#!/usr/bin/env bats
# Path containment + grep safety from lib/grounding.sh.

setup() {
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../lib/grounding.sh"
  PP_TEST_BASE="$(mktemp -d)"
  mkdir -p "$PP_TEST_BASE/sub/nested"
  echo "ok" > "$PP_TEST_BASE/sub/file.txt"
  echo "ok" > "$PP_TEST_BASE/sub/nested/deep.txt"
  # macOS mktemp returns /var/... which realpath resolves to /private/var/...;
  # capture the resolved form for prefix-match assertions.
  PP_TEST_BASE_REAL="$(cd "$PP_TEST_BASE" && pwd -P)"
  # A sibling dir OUTSIDE the base, to test escape attempts
  PP_TEST_OUTSIDE="$(mktemp -d)"
  echo "secret" > "$PP_TEST_OUTSIDE/secret.txt"
}

teardown() {
  rm -rf "$PP_TEST_BASE" "$PP_TEST_OUTSIDE"
}

@test "contain: accepts a file inside base" {
  run pp_contain_path "$PP_TEST_BASE" "sub/file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == "$PP_TEST_BASE_REAL"/* ]]
}

@test "contain: accepts a deep file inside base" {
  run pp_contain_path "$PP_TEST_BASE" "sub/nested/deep.txt"
  [ "$status" -eq 0 ]
}

@test "contain: rejects ../ traversal escaping base" {
  run pp_contain_path "$PP_TEST_BASE" "../$(basename "$PP_TEST_OUTSIDE")/secret.txt"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: rejects absolute path outside base" {
  run pp_contain_path "$PP_TEST_BASE" "/etc/passwd"
  [ "$status" -ne 0 ]
}

@test "contain: rejects empty candidate" {
  run pp_contain_path "$PP_TEST_BASE" ""
  [ "$status" -ne 0 ]
}

@test "contain: rejects when base does not exist" {
  run pp_contain_path "/nonexistent/path" "anything"
  [ "$status" -ne 0 ]
}

@test "contain: rejects candidate file that does not exist (cross-platform realpath fix)" {
  # GNU realpath (Ubuntu/CI) succeeds for non-existent paths by default;
  # BSD realpath (macOS) fails. Without the explicit [ -e ] guard in
  # pp_contain_path, Ubuntu CI gave false PASS to hallucinated cited paths
  # while macOS rejected them — see v0.5.2 CI failure cluster
  # (test/hallucination-gate.bats #329 etc.). This test pins the invariant
  # at the helper boundary so a future regression here surfaces before it
  # bleeds into all downstream OAR/hallucination tests.
  run pp_contain_path "$PP_TEST_BASE" "definitely-does-not-exist.ts"
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects empty pattern" {
  run pp_safe_grep_pattern ""
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects pure dot" {
  run pp_safe_grep_pattern "."
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects pure .*" {
  run pp_safe_grep_pattern ".*"
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects length 3" {
  run pp_safe_grep_pattern "abc"
  [ "$status" -ne 0 ]
}

@test "grep-safe: accepts reasonable identifier search" {
  run pp_safe_grep_pattern "TODO|FIXME"
  [ "$status" -eq 0 ]
}

@test "grep-safe: rejects > 100 char patterns" {
  local long
  long=$(printf 'a%.0s' $(seq 1 101))
  run pp_safe_grep_pattern "$long"
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects leading dash (option injection guard)" {
  run pp_safe_grep_pattern "-Roo"
  [ "$status" -ne 0 ]
  run pp_safe_grep_pattern "--include=foo"
  [ "$status" -ne 0 ]
}

@test "grep-safe: rejects alnum dwarfed by metachars" {
  # length>4 but only one alnum char — broad-match risk
  run pp_safe_grep_pattern "^.*a.*\$"
  [ "$status" -ne 0 ]
}

@test "grep-safe: accepts identifier with surrounding metachars" {
  # 3+ alnum chars present even with regex around them
  run pp_safe_grep_pattern "^budget_inc\\("
  [ "$status" -eq 0 ]
}

# === pp_is_secret_file + integration with pp_contain_path ===

@test "secret-file: rejects basename matching .env" {
  run pp_is_secret_file "/some/path/.env"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects .env.local" {
  run pp_is_secret_file "/some/path/.env.local"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects production.env" {
  run pp_is_secret_file "/x/production.env"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects .envrc" {
  run pp_is_secret_file "/x/.envrc"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects *.pem / *.key / *.p12 / *.pfx" {
  for ext in pem key p12 pfx; do
    run pp_is_secret_file "/x/server.$ext"
    [ "$status" -eq 0 ]
  done
}

@test "secret-file: rejects credentials.json / secrets.yml" {
  run pp_is_secret_file "/x/credentials.json"
  [ "$status" -eq 0 ]
  run pp_is_secret_file "/x/secrets.yml"
  [ "$status" -eq 0 ]
}

@test "secret-file: rejects id_rsa / id_ed25519 / authinfo / .netrc" {
  for f in id_rsa id_rsa.pub id_ed25519 authinfo .netrc; do
    run pp_is_secret_file "/x/$f"
    [ "$status" -eq 0 ]
  done
}

@test "secret-file: rejects .npmrc / .pypirc" {
  run pp_is_secret_file "/x/.npmrc"
  [ "$status" -eq 0 ]
  run pp_is_secret_file "/x/.pypirc"
  [ "$status" -eq 0 ]
}

@test "secret-file: ACCEPTS regular source files" {
  for f in App.tsx main.py README.md package.json Makefile build.gradle; do
    run pp_is_secret_file "/x/$f"
    [ "$status" -ne 0 ]
  done
}

@test "secret-file: PP_SECRET_FILE_PATTERNS_EXTRA adds patterns additively" {
  PP_SECRET_FILE_PATTERNS_EXTRA="*.myorg-secret" run pp_is_secret_file "/x/foo.myorg-secret"
  [ "$status" -eq 0 ]
  # Defaults still apply
  PP_SECRET_FILE_PATTERNS_EXTRA="*.myorg-secret" run pp_is_secret_file "/x/.env"
  [ "$status" -eq 0 ]
}

@test "secret-file: PP_SECRET_FILE_PATTERNS replaces defaults entirely (escape hatch)" {
  # Set patterns to something that does NOT match .env
  PP_SECRET_FILE_PATTERNS="*.totallyunrelated" run pp_is_secret_file "/x/.env"
  [ "$status" -ne 0 ]
}

@test "contain: now rejects .env even when inside base" {
  echo "sk-fake" > "$PP_TEST_BASE/sub/.env"
  run pp_contain_path "$PP_TEST_BASE" "sub/.env"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: now rejects deep credentials.json" {
  echo '{}' > "$PP_TEST_BASE/sub/nested/credentials.json"
  run pp_contain_path "$PP_TEST_BASE" "sub/nested/credentials.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: still accepts non-secret files inside base" {
  run pp_contain_path "$PP_TEST_BASE" "sub/file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == "$PP_TEST_BASE"/* ]] || [[ "$output" == "$PP_TEST_BASE_REAL"/* ]]
}

# === F1: case-insensitive matching (macOS APFS case-fold friendly) ===

@test "secret-file: case-insensitive — rejects .ENV, ID_RSA, Credentials.JSON, SERVER.PEM" {
  for f in .ENV ID_RSA Credentials.JSON SERVER.PEM; do
    run pp_is_secret_file "/x/$f"
    [ "$status" -eq 0 ]
  done
}

# === F2: expanded pattern list catches real-world credential filenames ===

@test "secret-file: expanded patterns — service-account, kubeconfig, wp-config, *_rsa, .pgpass, *_token" {
  for f in service-account-prod.json my.kubeconfig kubeconfig wp-config.php my_rsa my_dsa my_ed25519 .pgpass api_token build_secret my_apikey foo.private_key .git-credentials .aws_credentials; do
    run pp_is_secret_file "/x/$f"
    [ "$status" -eq 0 ]
  done
}

@test "secret-file: broadened *credentials* matches aws-credentials.json and gcp-credentials" {
  for f in aws-credentials.json gcp-credentials prod-credentials.yml; do
    run pp_is_secret_file "/x/$f"
    [ "$status" -eq 0 ]
  done
}

@test "secret-file: broadened *secrets* matches database-secrets and prod-secrets.yml" {
  for f in database-secrets prod-secrets.yml app-secrets.json; do
    run pp_is_secret_file "/x/$f"
    [ "$status" -eq 0 ]
  done
}

# === F3: path-component (dirname) denylist ===

@test "secret-file: rejects files inside secret-named directories" {
  # Round-3 G2: dir-component walk is RELATIVE-PATH only now. Absolute
  # paths get basename-only check to avoid /private/var false-positives.
  for p in "secrets/config.json" "private/db.yml" ".ssh/known_hosts" ".aws/config" ".credentials/token" ".keys/api" ".secrets/foo"; do
    run pp_is_secret_file "$p"
    [ "$status" -eq 0 ]
  done
}

@test "secret-file: dirname check is case-insensitive too" {
  run pp_is_secret_file "SECRETS/config.json"
  [ "$status" -eq 0 ]
  run pp_is_secret_file ".SSH/known_hosts"
  [ "$status" -eq 0 ]
}

@test "secret-file: dirname check does NOT trigger on innocuous paths" {
  for p in "src/main.py" "lib/grounding.sh" "test/foo.bats" "docs/README.md" "app/components/Button.tsx"; do
    run pp_is_secret_file "$p"
    [ "$status" -ne 0 ]
  done
}

@test "secret-file: PP_SECRET_DIR_PATTERNS_EXTRA adds dirname patterns additively" {
  PP_SECRET_DIR_PATTERNS_EXTRA="vault" run pp_is_secret_file "vault/key.txt"
  [ "$status" -eq 0 ]
  # Defaults still apply
  PP_SECRET_DIR_PATTERNS_EXTRA="vault" run pp_is_secret_file "secrets/x.txt"
  [ "$status" -eq 0 ]
}

@test "contain: rejects file inside secrets/ dir even with innocuous basename" {
  mkdir -p "$PP_TEST_BASE/secrets"
  echo "k" > "$PP_TEST_BASE/secrets/config.json"
  run pp_contain_path "$PP_TEST_BASE" "secrets/config.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: rejects file inside .ssh/ dir even with innocuous basename" {
  mkdir -p "$PP_TEST_BASE/.ssh"
  echo "h" > "$PP_TEST_BASE/.ssh/known_hosts"
  run pp_contain_path "$PP_TEST_BASE" ".ssh/known_hosts"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# === F4: symlink basename-trust — check BOTH candidate and realpath ===

@test "contain: rejects symlink whose link basename matches denylist (link → innocent target)" {
  echo "innocent" > "$PP_TEST_BASE/sub/innocent.txt"
  ( cd "$PP_TEST_BASE/sub" && ln -sf innocent.txt id_rsa )
  run pp_contain_path "$PP_TEST_BASE" "sub/id_rsa"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: rejects symlink whose realpath basename matches denylist (innocent link → secret target)" {
  echo "sk-fake" > "$PP_TEST_BASE/sub/aws_credentials_personal"
  ( cd "$PP_TEST_BASE/sub" && ln -sf aws_credentials_personal notes.txt )
  run pp_contain_path "$PP_TEST_BASE" "sub/notes.txt"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: rejects innocuous symlink that resolves into a secrets/ directory" {
  mkdir -p "$PP_TEST_BASE/secrets"
  echo "k" > "$PP_TEST_BASE/secrets/db.conf"
  ( cd "$PP_TEST_BASE/sub" && ln -sf ../secrets/db.conf app.config )
  run pp_contain_path "$PP_TEST_BASE" "sub/app.config"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# === F5: pathname-expansion immunity (set -f discipline) ===

@test "secret-file: glob patterns do NOT expand against cwd files" {
  # Create a file that would match `*.env` if globbing leaked.
  # If `*.env` expanded to literal `prod.env`, the case statement would only
  # match the basename "prod.env", not ".env" — which would be a regression.
  (
    cd "$PP_TEST_BASE/sub"
    : > prod.env
    : > foo.env
    # Now from inside this cwd, .env still has to match the literal *.env pattern.
    pp_is_secret_file ".env"
  )
  [ "$?" -eq 0 ]
}

@test "secret-file: glob expansion immunity also covers dirname patterns" {
  # Create a dir named "secrets" in cwd. If dirname patterns leaked, mixing
  # with the literal file pattern check could produce surprise matches.
  # Note: Round-3 G2 contract means we must pass a RELATIVE path to exercise
  # the dirname walk — absolute paths use basename-only.
  (
    cd "$PP_TEST_BASE/sub"
    mkdir -p secrets
    : > secrets/foo
    pp_is_secret_file "private/file.txt"
  )
  [ "$?" -eq 0 ]
}

# === F6: empty-string escape hatch (genuine '' disables; whitespace-only warns) ===

@test "secret-file: PP_SECRET_FILE_PATTERNS='' (explicit empty) disables basename check" {
  # With basename check disabled, .env should NOT match (also not in any
  # secret dir). Other check (dirname) still runs but matches nothing here.
  PP_SECRET_FILE_PATTERNS="" run pp_is_secret_file "/x/.env"
  [ "$status" -ne 0 ]
}

@test "secret-file: PP_SECRET_FILE_PATTERNS='' still allows dirname check to fire" {
  # File inside secrets/ should STILL be rejected via dir-pattern check even
  # when basename patterns are explicitly disabled. Use a relative path so
  # the dir-walk runs (Round-3 G2 contract: absolute → basename only).
  PP_SECRET_FILE_PATTERNS="" run pp_is_secret_file "secrets/config.json"
  [ "$status" -eq 0 ]
}

@test "secret-file: PP_SECRET_FILE_PATTERNS whitespace-only falls back to defaults with stderr warning" {
  run bash -c '. "$0" && PP_SECRET_FILE_PATTERNS="   " pp_is_secret_file "/x/.env"' "${BATS_TEST_DIRNAME}/../lib/grounding.sh"
  [ "$status" -eq 0 ]
}

@test "secret-file: PP_SECRET_DIR_PATTERNS='' (explicit empty) disables dirname check" {
  # With dir check disabled but basename check still on, an innocuous file
  # inside secrets/ should now pass.
  PP_SECRET_DIR_PATTERNS="" run pp_is_secret_file "secrets/config.json"
  [ "$status" -ne 0 ]
}

# === Round-3 N1: pp_is_secret_file preserves caller's `set -f` state ===

@test "pp_is_secret_file: preserves caller set -f state (was on)" {
  set -f
  pp_is_secret_file ".env" || true
  case "$-" in
    *f*) set +f ;;
    *)   set +f; echo "set -f leaked off!" >&2; return 1 ;;
  esac
}

@test "pp_is_secret_file: preserves caller set -f state (was off)" {
  set +f
  pp_is_secret_file ".env" || true
  case "$-" in
    *f*) set +f; echo "set -f leaked on!" >&2; return 1 ;;
    *)   : ;;
  esac
}

# === Round-3 G1: cwd-as-secret-dir bypass guard ===

@test "contain: rejects ALL files when base is itself a secret dir (.ssh)" {
  mkdir -p "$PP_TEST_BASE/.ssh"
  echo "host github" > "$PP_TEST_BASE/.ssh/config"
  echo "key" > "$PP_TEST_BASE/.ssh/known_hosts"
  run pp_contain_path "$PP_TEST_BASE/.ssh" "config"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run pp_contain_path "$PP_TEST_BASE/.ssh" "known_hosts"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "contain: rejects ALL files when base is itself a secret dir (secrets)" {
  mkdir -p "$PP_TEST_BASE/secrets"
  echo "x" > "$PP_TEST_BASE/secrets/data.json"
  run pp_contain_path "$PP_TEST_BASE/secrets" "data.json"
  [ "$status" -ne 0 ]
}

@test "pp_is_secret_dir_component: matches default dir patterns" {
  run pp_is_secret_dir_component ".ssh"
  [ "$status" -eq 0 ]
  run pp_is_secret_dir_component "secrets"
  [ "$status" -eq 0 ]
  run pp_is_secret_dir_component "src"
  [ "$status" -ne 0 ]
}

# === Round-3 G2: absolute paths skip dir-component walk ===

@test "secret-file: absolute path with /private component does NOT trigger dir-walk false-positive" {
  # On macOS, mktemp returns /var/... which realpath resolves to
  # /private/var/...; "private" is in dir defaults. Round-3 G2 says
  # absolute-path inputs use basename-only — so /private/var/foo/test.txt
  # must NOT be flagged as secret.
  run pp_is_secret_file "/private/var/folders/xx/foo/test.txt"
  [ "$status" -ne 0 ]
}

@test "secret-file: absolute path still flags secret BASENAME" {
  # Basename check still fires for absolute inputs.
  run pp_is_secret_file "/private/var/foo/.env"
  [ "$status" -eq 0 ]
}

# === Round-3 G3: empty PP_SECRET_FILE_PATTERNS also disables _EXTRA ===

@test "secret-file: PP_SECRET_FILE_PATTERNS='' also ignores _EXTRA (true off switch)" {
  # User set basename patterns to '' (explicit disable). _EXTRA must NOT
  # silently re-enable any matching — otherwise the off-switch is leaky.
  PP_SECRET_FILE_PATTERNS="" \
    PP_SECRET_FILE_PATTERNS_EXTRA="*.env" \
    run pp_is_secret_file ".env"
  [ "$status" -ne 0 ]
}

@test "secret-file: PP_SECRET_DIR_PATTERNS='' also ignores _EXTRA (true off switch)" {
  PP_SECRET_DIR_PATTERNS="" \
    PP_SECRET_DIR_PATTERNS_EXTRA="secrets" \
    run pp_is_secret_file "secrets/innocent.txt"
  [ "$status" -ne 0 ]
}

# === Round-3 G4: user EXTRA patterns are lowercased before match ===

@test "secret-file: uppercase _EXTRA glob still matches lowercase basename" {
  PP_SECRET_FILE_PATTERNS_EXTRA="*.PEM" run pp_is_secret_file "server.pem"
  [ "$status" -eq 0 ]
}

@test "secret-file: uppercase _EXTRA dirname still matches lowercase component" {
  PP_SECRET_DIR_PATTERNS_EXTRA="VAULT" run pp_is_secret_file "vault/key.txt"
  [ "$status" -eq 0 ]
}

# === Round-4 R4-3: dir-walk must not include the leaf basename ===
# A relative path that is JUST a basename (no parent dirs) must not be
# rejected by the dir-component walk. The leaf is already checked against
# file patterns separately; the dir walk's job is parent components only.

@test "secret-file: regular file named 'private' (not inside a private dir) is ACCEPTED" {
  run pp_is_secret_file "private"
  [ "$status" -ne 0 ]
}

@test "secret-file: regular file named '.aws' (not inside an .aws dir) is ACCEPTED" {
  run pp_is_secret_file ".aws"
  [ "$status" -ne 0 ]
}

@test "secret-file: regular file named '.ssh' (not inside a .ssh dir) is ACCEPTED" {
  run pp_is_secret_file ".ssh"
  [ "$status" -ne 0 ]
}

@test "secret-file: foo/private/bar.txt — 'private' as parent dir IS rejected" {
  run pp_is_secret_file "foo/private/bar.txt"
  [ "$status" -eq 0 ]
}

@test "secret-file: regular file named '.private_key' STILL rejected (basename pattern match)" {
  run pp_is_secret_file ".private_key"
  [ "$status" -eq 0 ]
}

# === Round-4 R4-1: pp_is_secret_dir_component escape-hatch parity ===
# PP_SECRET_DIR_PATTERNS='' should also disable _EXTRA, matching the
# behavior of pp_is_secret_file's PP_SECRET_FILE_PATTERNS=''.

@test "dir-component: PP_SECRET_DIR_PATTERNS='' also ignores _EXTRA (true off switch)" {
  PP_SECRET_DIR_PATTERNS="" \
    PP_SECRET_DIR_PATTERNS_EXTRA="vault" \
    run pp_is_secret_dir_component "vault"
  [ "$status" -ne 0 ]
}

# === Round-4 R4-4: whitespace detection via [:space:] not just space ===

@test "secret-file: tab-only PP_SECRET_FILE_PATTERNS treated as whitespace, uses defaults" {
  PP_SECRET_FILE_PATTERNS=$'\t\t' run pp_is_secret_file "config.env"
  [ "$status" -eq 0 ]
}

@test "secret-file: newline-only PP_SECRET_DIR_PATTERNS treated as whitespace, uses defaults" {
  PP_SECRET_DIR_PATTERNS=$'\n\n' run pp_is_secret_file "secrets/config.json"
  [ "$status" -eq 0 ]
}
