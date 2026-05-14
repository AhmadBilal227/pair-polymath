#!/usr/bin/env bats
# v0.5.1 Tier 0 — phase classifier F1-F7 fallback.
#
# These tests assert the fallback decision tree fires when pattern-match
# returns "unknown". The output now carries phase_source: pattern|fallback|unknown
# so downstream KPI rollups can attribute decisions.
#
# Note: tool fixtures use the .tool/.target/.summary schema consumed by
# pp_router_extract_signals (matches lib/router-signals.sh and the existing
# test/router-signals.bats). The plan's draft snippet used .name/.input/.output
# which the function does not parse — those keys would yield 0 counts and the
# fallback tests would never fire.

setup() {
  HOME="$(mktemp -d)"
  export HOME
  PP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PP_ROOT
}
teardown() { rm -rf "$HOME"; }

@test "F1: empty inputs → unknown honestly" {
  . "$PP_ROOT/lib/router-signals.sh"
  PP_GIT_STATUS_FIXTURE=""
  local _sig
  _sig=$(pp_router_extract_signals "" "[]")
  [ "$(printf '%s' "$_sig" | jq -r .phase)" = "unknown" ]
  [ "$(printf '%s' "$_sig" | jq -r .phase_source)" = "unknown" ]
}

@test "F2: test_passed + edit → drafting via fallback" {
  . "$PP_ROOT/lib/router-signals.sh"
  PP_GIT_STATUS_FIXTURE=""
  local _tools='[{"tool":"Bash","target":"pnpm test","summary":"5 passing"},{"tool":"Edit","target":"x.ts","summary":null}]'
  local _sig
  _sig=$(pp_router_extract_signals "" "$_tools")
  [ "$(printf '%s' "$_sig" | jq -r .phase)" = "drafting" ]
  [ "$(printf '%s' "$_sig" | jq -r .phase_source)" = "fallback" ]
}

@test "F5: read-heavy + clean tree → planning via fallback" {
  . "$PP_ROOT/lib/router-signals.sh"
  PP_GIT_STATUS_FIXTURE=""
  local _tools='[{"tool":"Read","target":"a.ts","summary":null},{"tool":"Read","target":"b.ts","summary":null},{"tool":"Read","target":"c.ts","summary":null}]'
  local _sig
  _sig=$(pp_router_extract_signals "" "$_tools")
  [ "$(printf '%s' "$_sig" | jq -r .phase)" = "planning" ]
  [ "$(printf '%s' "$_sig" | jq -r .phase_source)" = "fallback" ]
}

@test "F-default: phase_source field is always present" {
  . "$PP_ROOT/lib/router-signals.sh"
  PP_GIT_STATUS_FIXTURE=""
  local _sig
  _sig=$(pp_router_extract_signals "" "[]")
  [ -n "$(printf '%s' "$_sig" | jq -r '.phase_source // empty')" ]
}
