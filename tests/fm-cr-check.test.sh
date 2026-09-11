#!/usr/bin/env bash
# Behavior tests for bin/fm-cr-check.sh.
#
# The CR rail always escalates: firstmate never auto-publishes or auto-merges a
# code review, so recording a CR-ready task is a light metadata write with NO
# self-executing merge poll. These tests pin that fm-cr-check records exactly
# one validated canonical cr= line, arms no check.sh, replaces a prior cr=, and
# refuses a non-canonical URL or bad task id without touching metadata.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CR_CHECK="$ROOT/bin/fm-cr-check.sh"
VALID='https://code.amazon.com/reviews/CR-284538794'
VALID2='https://code.amazon.com/reviews/CR-999000111'

setup_home() {
  local home=$1 id=$2
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/wt" \
    "mode=direct-PR" \
    "yolo=off"
}

test_records_and_arms_no_poll() {
  local home id out status meta
  home=$(fm_test_tmproot fm-cr-record)
  id=cr-record-1
  setup_home "$home" "$id"
  meta="$home/state/$id.meta"
  out=$(FM_HOME="$home" "$CR_CHECK" "$id" "$VALID" 2>&1); status=$?
  expect_code 0 "$status" "recording a valid CR must exit 0"
  assert_contains "$out" "recorded: cr=$VALID" "fm-cr-check must confirm the recorded CR"
  assert_grep "cr=$VALID" "$meta" "meta must carry the recorded cr= line"
  assert_equals 1 "$(grep -c '^cr=' "$meta")" "exactly one cr= line"
  # The CR rail arms no self-executing merge poll.
  assert_absent "$home/state/$id.check.sh" "fm-cr-check must not arm a merge poll"
  assert_absent "$home/state/$id.pr-poll" "fm-cr-check must not write a PR-poll sidecar"
  pass "fm-cr-check: records one cr= line and arms no poll"
}

test_replaces_prior_cr() {
  local home id meta
  home=$(fm_test_tmproot fm-cr-replace)
  id=cr-replace-1
  setup_home "$home" "$id"
  meta="$home/state/$id.meta"
  FM_HOME="$home" "$CR_CHECK" "$id" "$VALID" >/dev/null 2>&1 || fail "first record failed"
  FM_HOME="$home" "$CR_CHECK" "$id" "$VALID2" >/dev/null 2>&1 || fail "second record failed"
  assert_equals 1 "$(grep -c '^cr=' "$meta")" "a re-record must not stack cr= lines"
  assert_grep "cr=$VALID2" "$meta" "meta must carry the newest cr="
  assert_no_grep "cr=$VALID" "$meta" "the prior cr= must be replaced"
  # Other metadata lines survive the rewrite.
  assert_grep "mode=direct-PR" "$meta" "unrelated meta lines must survive"
  pass "fm-cr-check: a re-record replaces the prior cr= line"
}

test_rejects_bad_input() {
  local home id meta out status
  home=$(fm_test_tmproot fm-cr-reject)
  id=cr-reject-1
  setup_home "$home" "$id"
  meta="$home/state/$id.meta"
  out=$(FM_HOME="$home" "$CR_CHECK" "$id" 'https://github.com/o/r/pull/1' 2>&1); status=$?
  expect_code 2 "$status" "a forge PR URL must be refused"
  assert_no_grep "cr=" "$meta" "a refused URL must not touch metadata"
  out=$(FM_HOME="$home" "$CR_CHECK" '../escape' "$VALID" 2>&1); status=$?
  expect_code 2 "$status" "a path-unsafe task id must be refused"
  out=$(FM_HOME="$home" "$CR_CHECK" "$id" 2>&1); status=$?
  expect_code 2 "$status" "a missing URL argument must be refused"
  pass "fm-cr-check: refuses non-canonical URLs and unsafe ids without writing"
}

test_missing_meta() {
  local home id status
  home=$(fm_test_tmproot fm-cr-nometa)
  id=cr-nometa-1
  mkdir -p "$home/state"
  FM_HOME="$home" "$CR_CHECK" "$id" "$VALID" >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "an absent task metadata file must fail"
  pass "fm-cr-check: refuses when task metadata is absent"
}

test_records_and_arms_no_poll
test_replaces_prior_cr
test_rejects_bad_input
test_missing_meta
