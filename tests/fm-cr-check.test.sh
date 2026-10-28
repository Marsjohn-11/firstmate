#!/usr/bin/env bash
# Behavior tests for bin/fm-cr-check.sh.
#
# Recording a CR-ready task writes exactly one validated canonical cr= line and
# arms a registered watcher shim for bin/fm-cr-poll.sh (its own suite,
# tests/fm-cr-poll.test.sh, pins what the poll reports). A re-record replaces
# the prior cr= and drops poll sidecars that describe another review; a
# non-canonical URL or bad task id is refused without touching metadata.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CR_CHECK="$ROOT/bin/fm-cr-check.sh"
VALID='https://code.amazon.com/reviews/CR-284538794'
VALID2='https://code.amazon.com/reviews/CR-999000111'
GUARD_ROOT=$(fm_test_tmproot fm-cr-check-guard)
mkdir -p "$GUARD_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GUARD_ROOT/bin/fm-guard.sh"
chmod +x "$GUARD_ROOT/bin/fm-guard.sh"

# cr_check <home> <args...>: run fm-cr-check with a no-op supervision guard.
cr_check() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$GUARD_ROOT" FM_HOME="$home" "$CR_CHECK" "$@"
}

setup_home() {
  local home=$1 id=$2
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/wt" \
    "mode=direct-PR" \
    "yolo=off"
}

test_records_and_arms_registered_poll() {
  local home id out status meta
  home=$(fm_test_tmproot fm-cr-record)
  id=cr-record-1
  setup_home "$home" "$id"
  meta="$home/state/$id.meta"
  out=$(cr_check "$home" "$id" "$VALID" 2>&1); status=$?
  expect_code 0 "$status" "recording a valid CR must exit 0"
  assert_contains "$out" "recorded: cr=$VALID" "fm-cr-check must confirm the recorded CR"
  assert_grep "cr=$VALID" "$meta" "meta must carry the recorded cr= line"
  assert_equals 1 "$(grep -c '^cr=' "$meta")" "exactly one cr= line"
  assert_contains "$out" "armed: state/$id.check.sh polls $VALID" "fm-cr-check must confirm the armed poll"
  assert_present "$home/state/$id.check.sh" "fm-cr-check must arm the review poll"
  assert_present "$home/state/$id.check-trust" "the poll must be bound to its bytes for the watcher"
  assert_absent "$home/state/$id.pr-poll" "fm-cr-check must not write a PR-poll sidecar"
  bash -n "$home/state/$id.check.sh" || fail "the armed shim must be valid bash"
  (
    # shellcheck source=bin/fm-pr-lib.sh
    . "$ROOT/bin/fm-pr-lib.sh"
    # shellcheck source=bin/fm-check-lib.sh
    . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$home/state" "$id"
  ) || fail "the armed shim must pass the watcher's trust check"
  pass "fm-cr-check: records one cr= line and arms a registered poll"
}

test_replaces_prior_cr() {
  local home id meta
  home=$(fm_test_tmproot fm-cr-replace)
  id=cr-replace-1
  setup_home "$home" "$id"
  meta="$home/state/$id.meta"
  cr_check "$home" "$id" "$VALID" >/dev/null 2>&1 || fail "first record failed"
  cr_check "$home" "$id" "$VALID2" >/dev/null 2>&1 || fail "second record failed"
  assert_equals 1 "$(grep -c '^cr=' "$meta")" "a re-record must not stack cr= lines"
  assert_grep "cr=$VALID2" "$meta" "meta must carry the newest cr="
  assert_no_grep "cr=$VALID" "$meta" "the prior cr= must be replaced"
  # Other metadata lines survive the rewrite.
  assert_grep "mode=direct-PR" "$meta" "unrelated meta lines must survive"
  pass "fm-cr-check: a re-record replaces the prior cr= line"
}

test_rerecord_drops_other_review_sidecars() {
  local home id state
  home=$(fm_test_tmproot fm-cr-sidecars)
  id=cr-sidecars-1
  setup_home "$home" "$id"
  state="$home/state"
  cr_check "$home" "$id" "$VALID" >/dev/null 2>&1 || fail "first record failed"
  printf 'cr=%s\nstate=in-review\n' "$VALID" > "$state/$id.cr-seen"
  printf 'cr=%s\nstate=ok\n' "$VALID" > "$state/$id.cr-dest-seen"
  cr_check "$home" "$id" "$VALID" >/dev/null 2>&1 || fail "re-record of the same review failed"
  assert_grep 'state=in-review' "$state/$id.cr-seen" "re-recording the same review keeps its poll state"
  cr_check "$home" "$id" "$VALID2" >/dev/null 2>&1 || fail "record of another review failed"
  assert_absent "$state/$id.cr-seen" "another review's poll state must not carry over"
  assert_absent "$state/$id.cr-dest-seen" "another review's destination state must not carry over"
  assert_grep "$VALID2" "$state/$id.check.sh" "the shim must poll the newly recorded review"
  pass "fm-cr-check: a re-record keeps its own poll state and drops another review's"
}

test_refuses_task_with_pr_poll() {
  local home id status
  home=$(fm_test_tmproot fm-cr-prpoll)
  id=cr-prpoll-1
  setup_home "$home" "$id"
  printf 'x\n' > "$home/state/$id.pr-poll"
  cr_check "$home" "$id" "$VALID" >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "a task with a PR poll must not also arm a review poll"
  assert_absent "$home/state/$id.check.sh" "the PR poll's check must not be overwritten"
  pass "fm-cr-check: refuses to arm over a task's PR poll"
}

test_rejects_bad_input() {
  local home id meta out status
  home=$(fm_test_tmproot fm-cr-reject)
  id=cr-reject-1
  setup_home "$home" "$id"
  meta="$home/state/$id.meta"
  out=$(cr_check "$home" "$id" 'https://github.com/o/r/pull/1' 2>&1); status=$?
  expect_code 2 "$status" "a forge PR URL must be refused"
  assert_no_grep "cr=" "$meta" "a refused URL must not touch metadata"
  out=$(cr_check "$home" '../escape' "$VALID" 2>&1); status=$?
  expect_code 2 "$status" "a path-unsafe task id must be refused"
  out=$(cr_check "$home" "$id" 2>&1); status=$?
  expect_code 2 "$status" "a missing URL argument must be refused"
  pass "fm-cr-check: refuses non-canonical URLs and unsafe ids without writing"
}

test_missing_meta() {
  local home id status
  home=$(fm_test_tmproot fm-cr-nometa)
  id=cr-nometa-1
  mkdir -p "$home/state"
  cr_check "$home" "$id" "$VALID" >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "an absent task metadata file must fail"
  pass "fm-cr-check: refuses when task metadata is absent"
}

test_records_and_arms_registered_poll
test_replaces_prior_cr
test_rerecord_drops_other_review_sidecars
test_refuses_task_with_pr_poll
test_rejects_bad_input
test_missing_meta
