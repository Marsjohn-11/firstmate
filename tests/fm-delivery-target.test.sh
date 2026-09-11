#!/usr/bin/env bash
# Behavior tests for bin/fm-delivery-target-lib.sh and bin/fm-delivery-target.sh.
#
# The rail classifier reads the origin host on purpose (unlike
# bin/fm-project-origin-lib.sh, which forbids any host judgement): an Amazon
# gitfarm origin ships via a CRUX code review, everything else via a forge
# PR/MR, and an unreadable origin defaults to the forge path rather than the CR
# rail. fm_cr_url_parse accepts only the canonical CR URL shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-delivery-target-lib.sh
. "$ROOT/bin/fm-delivery-target-lib.sh"

CLI="$ROOT/bin/fm-delivery-target.sh"

test_host_extraction() {
  assert_equals git.amazon.com "$(fm_delivery_host_from_origin 'ssh://git.amazon.com:2222/pkg/RewindApp')" "ssh host with port"
  assert_equals git.amazon.com "$(fm_delivery_host_from_origin 'https://git.amazon.com/pkg/RewindApp')" "https host"
  assert_equals github.com "$(fm_delivery_host_from_origin 'git@github.com:org/repo.git')" "scp-like host"
  assert_equals gitlab.example.com "$(fm_delivery_host_from_origin 'https://user@gitlab.example.com:8443/g/p')" "userinfo and port stripped"
  fm_delivery_host_from_origin '' && fail "empty origin must not yield a host"
  fm_delivery_host_from_origin 'not a url with spaces' && fail "whitespace origin must be rejected"
  pass "fm-delivery-target: host extraction across scheme and scp-like forms"
}

test_target_classification() {
  assert_equals crux-cr "$(fm_delivery_target_from_origin 'ssh://git.amazon.com:2222/pkg/RewindApp')" "gitfarm ssh is crux-cr"
  assert_equals crux-cr "$(fm_delivery_target_from_origin 'https://code.amazon.com/packages/RewindApp')" "code.amazon.com is crux-cr"
  assert_equals crux-cr "$(fm_delivery_target_from_origin 'https://tiny.git.amazon.com/pkg/X')" "amazon subdomain is crux-cr"
  assert_equals forge "$(fm_delivery_target_from_origin 'git@github.com:amazonmusic/reverb-graphql.git')" "github is forge"
  assert_equals forge "$(fm_delivery_target_from_origin 'https://gitlab.example.com/g/p')" "gitlab is forge"
  assert_equals forge "$(fm_delivery_target_from_origin 'https://bitbucket.org/o/r')" "bitbucket is forge"
  # A host that merely contains "amazon" but is not the amazon.com domain is a forge.
  assert_equals forge "$(fm_delivery_target_from_origin 'https://amazon.com.evil.example/o/r')" "lookalike host is forge"
  assert_equals forge "$(fm_delivery_target_from_origin 'garbage with spaces')" "unparseable origin defaults to forge"
  assert_equals forge "$(fm_delivery_target_from_origin '')" "empty origin defaults to forge"
  pass "fm-delivery-target: only the amazon.com domain routes to the CR rail"
}

test_cr_url_parse() {
  fm_cr_url_parse 'https://code.amazon.com/reviews/CR-284538794' || fail "canonical CR URL must parse"
  assert_equals 'https://code.amazon.com/reviews/CR-284538794' "$FM_CR_URL" "FM_CR_URL round-trips"
  assert_equals 'CR-284538794' "$FM_CR_ID" "FM_CR_ID captured"
  fm_cr_url_parse 'https://code.amazon.com/reviews/CR-0' && fail "CR-0 must be rejected"
  fm_cr_url_parse 'https://code.amazon.com/reviews/CR-12/files' && fail "trailing path must be rejected"
  fm_cr_url_parse 'https://code.amazon.com/reviews/CR-12?tab=x' && fail "query string must be rejected"
  fm_cr_url_parse 'http://code.amazon.com/reviews/CR-12' && fail "http scheme must be rejected"
  fm_cr_url_parse 'https://github.com/o/r/pull/1' && fail "a forge PR URL must be rejected"
  # A rejected parse clears the globals so a stale value cannot leak forward.
  [ -z "$FM_CR_URL" ] && [ -z "$FM_CR_ID" ] || fail "a rejected CR URL must clear FM_CR_URL/FM_CR_ID"
  pass "fm-delivery-target: only the canonical CR URL shape parses"
}

test_target_of_dir() {
  local root repo_cr repo_forge repo_none plain
  root=$(fm_test_tmproot fm-delivery-of-dir)
  repo_cr="$root/cr"; repo_forge="$root/forge"; repo_none="$root/none"; plain="$root/plain"
  for r in "$repo_cr" "$repo_forge" "$repo_none"; do
    mkdir -p "$r"; git -C "$r" init -q -b main
  done
  git -C "$repo_cr" remote add origin 'ssh://git.amazon.com:2222/pkg/RewindApp'
  git -C "$repo_forge" remote add origin 'git@github.com:org/repo.git'
  mkdir -p "$plain"
  assert_equals crux-cr "$(fm_delivery_target_of_dir "$repo_cr")" "gitfarm-origin repo is crux-cr"
  assert_equals forge "$(fm_delivery_target_of_dir "$repo_forge")" "github-origin repo is forge"
  assert_equals forge "$(fm_delivery_target_of_dir "$repo_none")" "repo with no origin defaults to forge"
  assert_equals forge "$(fm_delivery_target_of_dir "$plain")" "non-git directory defaults to forge"
  pass "fm-delivery-target: directory classification reads the origin remote"
}

test_cli() {
  local root repo out status
  root=$(fm_test_tmproot fm-delivery-cli)
  repo="$root/repo"; mkdir -p "$repo"; git -C "$repo" init -q -b main
  git -C "$repo" remote add origin 'ssh://git.amazon.com:2222/pkg/RewindApp'
  assert_equals crux-cr "$("$CLI" "$repo")" "CLI dir mode classifies the repo"
  assert_equals crux-cr "$("$CLI" --origin 'https://code.amazon.com/packages/X')" "CLI --origin classifies a URL"
  assert_equals forge "$("$CLI" --origin 'https://github.com/o/r')" "CLI --origin forge"
  "$CLI" --help >/dev/null 2>&1 || fail "--help must exit 0"
  out=$("$CLI" 2>&1); status=$?; expect_code 2 "$status" "no argument"
  assert_contains "$out" "usage" "no-argument error explains usage"
  out=$("$CLI" --origin 2>&1); status=$?; expect_code 2 "$status" "--origin without a URL"
  out=$("$CLI" --bogus 2>&1); status=$?; expect_code 2 "$status" "unknown option"
  out=$("$CLI" "$root/does-not-exist" 2>&1); status=$?; expect_code 2 "$status" "missing directory"
  pass "fm-delivery-target.sh: CLI modes, help, and argument errors"
}

test_host_extraction
test_target_classification
test_cr_url_parse
test_target_of_dir
test_cli
