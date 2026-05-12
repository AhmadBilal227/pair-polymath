#!/usr/bin/env bats
setup() {
  export PP_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  # shellcheck disable=SC1091
  . "$PP_ROOT/lib/memory/redact.sh"
}
teardown() { rm -rf "$SANDBOX"; }

@test "redact: OpenAI sk- token stripped" {
  out=$(pp_memory_redact_body "leak sk-abcdefghij1234567890ABCD trailing")
  [[ "$out" != *"sk-abcdefghij1234567890ABCD"* ]]
  [[ "$out" == *"[REDACTED-OPENAI]"* ]]
}

@test "redact: Bearer token stripped" {
  out=$(pp_memory_redact_body "header: Bearer abcdef1234567890ABCDEFGHIJ.foo end")
  [[ "$out" != *"abcdef1234567890ABCDEFGHIJ"* ]]
  [[ "$out" == *"[REDACTED-BEARER]"* ]]
}

@test "redact: GitHub ghp_ token stripped" {
  out=$(pp_memory_redact_body "token=ghp_abcdef1234567890ABCDEFGH end")
  [[ "$out" != *"ghp_abcdef1234567890ABCDEFGH"* ]]
  [[ "$out" == *"[REDACTED-GHP]"* ]]
}

@test "redact: GitHub fine-grained github_pat_ token stripped" {
  out=$(pp_memory_redact_body "github_pat_11ABC1234567890abcdefghij_more end")
  [[ "$out" != *"github_pat_11ABC1234567890abcdefghij_more"* ]]
  [[ "$out" == *"[REDACTED-GHPAT]"* ]]
}

@test "redact: AWS access-key AKIA stripped" {
  out=$(pp_memory_redact_body "aws_access=AKIAIOSFODNN7EXAMPLE done")
  [[ "$out" != *"AKIAIOSFODNN7EXAMPLE"* ]]
  [[ "$out" == *"[REDACTED-AWS]"* ]]
}

@test "redact: Slack xox token stripped" {
  # Assemble a Slack-shaped token at runtime to avoid tripping
  # GitHub push-protection secret scanning on this test source file.
  local tok="xoxb-FAKE-TESTING-ONLY-NOT-REAL-aaaaa"
  out=$(pp_memory_redact_body "slack=$tok done")
  [[ "$out" != *"FAKE-TESTING-ONLY-NOT-REAL"* ]]
  [[ "$out" == *"[REDACTED-SLACK]"* ]]
}

@test "redact: .env path reference stripped" {
  out=$(pp_memory_redact_body "see /home/user/project/.env.production for keys")
  [[ "$out" != *".env.production"* ]]
  [[ "$out" == *"[REDACTED-DOTENV]"* ]]
}

@test "redact: bare .env path stripped" {
  out=$(pp_memory_redact_body "read /etc/.env for vars")
  [[ "$out" == *"[REDACTED-DOTENV]"* ]]
}

@test "redact: word 'environment' is NOT redacted" {
  out=$(pp_memory_redact_body "the production environment is healthy")
  [ "$out" = "the production environment is healthy" ]
}

@test "redact: .envrc (direnv) is NOT redacted" {
  out=$(pp_memory_redact_body "edit .envrc to add a hook")
  [[ "$out" == *".envrc"* ]]
}

@test "redact: prose preserved with only path-occurrence redacted" {
  out=$(pp_memory_redact_body "documentation about .env files lives here")
  # The trailing ".env " in path form should be redacted; the prose words remain.
  [[ "$out" == *"documentation about"* ]]
  [[ "$out" == *"files lives here"* ]]
  [[ "$out" == *"[REDACTED-DOTENV]"* ]]
}

@test "redact: email address stripped" {
  out=$(pp_memory_redact_body "contact alice@example.com today")
  [[ "$out" != *"alice@example.com"* ]]
  [[ "$out" == *"[REDACTED-EMAIL]"* ]]
}

@test "redact: Stripe live key stripped" {
  # Build the fake key at runtime so the literal doesn't trip GitHub
  # Push Protection on the fixture itself (the Stripe scanner detects
  # the contiguous string pattern). Still matches the regex.
  prefix="sk_live"
  body="NOTREALaaaaaaaaaaaaaaaaaaaa"
  fake_key="${prefix}_${body}"
  out=$(pp_memory_redact_body "stripe $fake_key done")
  [[ "$out" != *"$fake_key"* ]]
  [[ "$out" == *"[REDACTED-STRIPE]"* ]]
}

@test "redact: JWT token stripped" {
  jwt="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
  out=$(pp_memory_redact_body "auth=$jwt end")
  [[ "$out" != *"eyJhbGciOiJIUzI1NiJ9"* ]]
  [[ "$out" == *"[REDACTED-JWT]"* ]]
}

@test "redact: Postgres connection URI stripped" {
  out=$(pp_memory_redact_body "DATABASE_URL=postgres://user:pass@host:5432/db trail")
  [[ "$out" != *"user:pass@host"* ]]
  [[ "$out" == *"[REDACTED-DBURI]"* ]]
}

@test "redact: MongoDB SRV URI stripped" {
  out=$(pp_memory_redact_body "uri=mongodb+srv://u:p@cluster.example.com/db end")
  [[ "$out" != *"u:p@cluster.example.com"* ]]
  [[ "$out" == *"[REDACTED-DBURI]"* ]]
}

@test "redact: clean text passes through unchanged" {
  out=$(pp_memory_redact_body "no secrets in here, just words")
  [ "$out" = "no secrets in here, just words" ]
}

@test "redact-path: path inside cwd is allowed (echoed)" {
  mkdir -p "$SANDBOX/cwd/sub"
  touch "$SANDBOX/cwd/sub/file.txt"
  out=$(pp_memory_redact_path "sub/file.txt" "$SANDBOX/cwd")
  [ -n "$out" ]
  [ "$out" = "sub/file.txt" ]
}

@test "redact-path: path outside cwd is rejected (empty stdout)" {
  mkdir -p "$SANDBOX/cwd"
  mkdir -p "$SANDBOX/outside"
  touch "$SANDBOX/outside/secret.txt"
  out=$(pp_memory_redact_path "../outside/secret.txt" "$SANDBOX/cwd")
  [ -z "$out" ]
}

@test "redact-path: absolute path outside cwd is rejected" {
  mkdir -p "$SANDBOX/cwd"
  touch "$SANDBOX/elsewhere.txt"
  out=$(pp_memory_redact_path "/etc/passwd" "$SANDBOX/cwd")
  [ -z "$out" ]
}
