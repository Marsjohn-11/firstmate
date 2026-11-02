#!/usr/bin/env bash
# Behavior tests for bin/fm-cr-analyzers.sh, the analyzer gate firstmate runs
# before relaying a code review as ready.
#
# Verdicts are GREEN (0), RED (1, including a CRUX merge failure), ABSTAINED (3, a gating Pass measured
# nothing), and UNREADABLE (4). A non-Pass analyzer required for nothing, and an
# Integration Tests Skipped with a listed structural reason, is advisory.
# Most cases inject a captured analyzer fixture through FM_CR_ANALYZERS_BODY;
# the unreadable cases drive the real fetch path with a failing fake mcurl.
# Captured RewindApp-style fixtures carry Change Guardian's real "Analysis was
# skipped" Pass, so their verdict is ABSTAINED rather than GREEN.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ANALYZERS="$ROOT/bin/fm-cr-analyzers.sh"
FIXTURES="$ROOT/tests/fixtures/cr-analyzers"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-cr-analyzers-tests)

# run_body <cr-id> <fixture-file>: run the check with the fixture injected as the
# analyzer body (no network). Sets LAST_OUT to combined stdout+stderr and
# LAST_STATUS to the exit code. Both are globals rather than captured through a
# command substitution so the exit code survives into the calling test (a status
# assigned inside a $() subshell would never reach the parent).
LAST_OUT=
LAST_STATUS=0
run_body() {
  local cr=$1 fixture=$2
  LAST_STATUS=0
  LAST_OUT=$(FM_CR_ANALYZERS_BODY="$(cat "$FIXTURES/$fixture")" "$ANALYZERS" "$cr" 2>&1) || LAST_STATUS=$?
}

# ---------------------------------------------------------------------------
# GREEN: every merge-gating analyzer Pass

test_all_green_exits_zero() {
  local out
  run_body CR-1000001 all-green.json
  out=$LAST_OUT
  expect_code 0 "$LAST_STATUS" "all-green should exit 0"
  assert_contains "$out" "GREEN" "green verdict should be printed"
  assert_not_contains "$out" "RED" "a green CR must not be reported red"
  assert_not_contains "$out" "advisory" "an all-green CR with no non-Pass analyzers has no advisory line"
  pass "all merge-gating analyzers Pass => GREEN, exit 0"
}

test_fallback_shape_green() {
  # The builder-mcp body nests analyzers under .content; the check must parse it
  # the same as the top-level mcurl shape.
  local out
  run_body CR-1000002 fallback-shape-green.json
  out=$LAST_OUT
  expect_code 0 "$LAST_STATUS" "content-wrapped green body should exit 0"
  assert_contains "$out" "GREEN" "the .content.analyzers shape should still read green"
  pass "the builder-mcp .content.analyzers shape parses to GREEN"
}

# ---------------------------------------------------------------------------
# RED: a merge-gating analyzer is not Pass

test_merge_gating_red_names_the_blocker() {
  local out
  run_body CR-2000001 merge-gating-red.json
  out=$LAST_OUT
  expect_code 1 "$LAST_STATUS" "a merge-gating failure should exit non-zero"
  assert_contains "$out" "RED" "red verdict should be printed"
  # The blocker is named with its reason so firstmate can relay it.
  assert_contains "$out" "Dry Run Build" "the blocking analyzer must be named"
  assert_contains "$out" "Fail" "the blocker's status must be shown"
  assert_contains "$out" "compilation error in FooService" "the blocker's status_message (the real reason) must be shown"
  pass "a not-Pass merge-gating analyzer => RED, exit 1, named with its reason"
}

test_merge_gating_red_keeps_advisory_out_of_blockers() {
  # merge-gating-red.json also carries an AutoSDE Fault with empty
  # pass_required_for. It must appear under advisory, never as a blocker, even
  # when the CR is red for a separate merge-gating failure.
  local out blocker_section advisory_section
  run_body CR-2000002 merge-gating-red.json
  out=$LAST_OUT
  assert_contains "$out" "advisory (not blocking)" "the advisory analyzer should be shown on its own labeled line"
  assert_contains "$out" "AutoSDE" "the advisory analyzer should still be mentioned"
  # AutoSDE must be under the advisory heading, not under the RED blocker heading.
  blocker_section=$(printf '%s' "$out" | sed -n '/^RED:/,/^advisory/p')
  assert_not_contains "$blocker_section" "AutoSDE" "an advisory analyzer must not appear among the merge-gating blockers"
  advisory_section=$(printf '%s' "$out" | sed -n '/^advisory/,$p')
  assert_contains "$advisory_section" "AutoSDE" "the advisory analyzer belongs under the advisory heading"
  pass "on the red path, a non-gating non-Pass analyzer stays advisory, not a blocker"
}

# ---------------------------------------------------------------------------
# RED: CRUX failed to merge the review, even with every analyzer Pass

test_could_not_run_merge_conflict_is_red() {
  local out
  run_body CR-7000001 merge-conflict-could-not-run.json
  out=$LAST_OUT
  expect_code 1 "$LAST_STATUS" "a MergeService merge-conflict comment must turn the gate red"
  assert_contains "$out" "RED: https://code.amazon.com/reviews/CR-7000001 - CRUX could not merge this review" "the red verdict names the merge failure"
  assert_contains "$out" "CRUX merge: conflict - Package ExamplePackage had merge conflicts (CRUX Auto-Merge could not run)" "the blocker names the conflicting package and the comment title"
  assert_contains "$out" "auto-merge was cleared, so CRUX will not retry" "a cleared auto-merge is named"
  assert_not_contains "$out" "GREEN" "green analyzers must not hide a merge conflict"
  pass "a CRUX Auto-Merge could not run comment with a merge conflict => RED, exit 1"
}

test_merge_failed_banner_text_is_red() {
  # The builder-mcp shape, with the review page's banner text in a merge
  # status field and auto-merge still armed.
  local out
  run_body CR-7000002 merge-failed-banner-fallback.json
  out=$LAST_OUT
  expect_code 1 "$LAST_STATUS" "Merge failed. Package <X> had merge conflicts. must turn the gate red"
  assert_contains "$out" "CRUX merge: conflict - Package ExamplePackage had merge conflicts" "the blocker names the package from the banner text"
  assert_not_contains "$out" "auto-merge was cleared" "an armed auto-merge is not reported cleared"
  pass "Merge failed. Package <X> had merge conflicts. in the merge status => RED, exit 1"
}

test_failed_merge_with_auto_merge_cleared_is_red() {
  local out
  run_body CR-7000003 merge-failed-auto-merge-cleared.json
  out=$LAST_OUT
  expect_code 1 "$LAST_STATUS" "a failed merge that cleared auto-merge must turn the gate red"
  assert_contains "$out" "CRUX merge: failed - CRUX Auto-Merge failed" "the blocker names the failed merge"
  assert_contains "$out" "auto-merge was cleared, so CRUX will not retry" "the cleared auto-merge is named"
  pass "a failed merge with auto-merge cleared and no conflict => RED, exit 1"
}

test_merge_failure_red_keeps_analyzer_blockers() {
  local body out status=0
  body=$(jq -c '.analyzers[0].status = "Fail" | .analyzers[0].status_message = "1 build failed"' "$FIXTURES/merge-conflict-could-not-run.json")
  out=$(FM_CR_ANALYZERS_BODY="$body" "$ANALYZERS" CR-7000004 2>&1) || status=$?
  expect_code 1 "$status" "a merge failure plus a failing analyzer is red"
  assert_contains "$out" "CRUX merge: conflict" "the merge failure is named"
  assert_contains "$out" "Dry Run Build: Fail - 1 build failed" "the failing analyzer is still named"
  pass "a merge failure and a failing analyzer are both named on the red path"
}

# assert_merge_failure_ignored <cr> <jq-filter> <why>: the filter applied to the
# merge-conflict fixture leaves no live merge failure, so the gate is not red.
assert_merge_failure_ignored() {
  local cr=$1 filter=$2 why=$3 body out status=0
  body=$(jq -c "$filter" "$FIXTURES/merge-conflict-could-not-run.json")
  out=$(FM_CR_ANALYZERS_BODY="$body" "$ANALYZERS" "$cr" 2>&1) || status=$?
  expect_code 0 "$status" "$why"
  assert_not_contains "$out" "CRUX merge" "$why"
}

test_merge_failure_ignored_when_not_live() {
  assert_merge_failure_ignored CR-7000005 '.revision.cr_revision.id.review_revision_id.revision = 3'     "a merge failure on an earlier revision is superseded by the latest revision"
  assert_merge_failure_ignored CR-7000006 '.revision.cr_revision.status = "SHIPPED"'     "a shipped review has no live merge failure"
  assert_merge_failure_ignored CR-7000007 '.revision.cr_revision.comments[0].cr_comment.content = "## ✅ CRUX Auto-Merge succeeded"'     "a merge success comment is not a failure"
  assert_merge_failure_ignored CR-7000008 '.revision.cr_revision.comments[0].cr_comment.author.entity_id = {"type":"USER","id":"reviewer"}'     "a reviewer quoting the failure text is not CRUX reporting one"
  pass "a superseded, shipped, successful, or quoted merge failure leaves the gate green"
}

# ---------------------------------------------------------------------------
# Advisory-only: a non-Pass analyzer required for nothing (captured fixture)

test_advisory_only_is_not_red_with_advisory_line() {
  # advisory-only.json is captured from a real CR: every merge-gating analyzer
  # Pass, plus Shepherd CodeGuard Blocked with empty pass_required_for. A
  # non-Pass analyzer required for nothing never turns the gate red. Its
  # Change Guardian Pass abstained, so the verdict is ABSTAINED.
  local out
  run_body CR-3000001 advisory-only.json
  out=$LAST_OUT
  expect_code 3 "$LAST_STATUS" "an advisory-only non-Pass analyzer must not fail the gate"
  assert_contains "$out" "ABSTAINED" "the abstaining Change Guardian Pass keeps it from green"
  assert_not_contains "$out" "RED" "an advisory-only non-Pass analyzer must never be reported red"
  assert_contains "$out" "advisory (not blocking)" "the advisory line must be clearly labeled"
  assert_contains "$out" "Shepherd CodeGuard" "the advisory analyzer must be mentioned so firstmate can relay it"
  assert_contains "$out" "Blocked" "the advisory analyzer's status should be shown"
  pass "advisory-only non-Pass => not red, with a clearly-labeled advisory line"
}

# ---------------------------------------------------------------------------
# Integration Tests Skipped: only the listed structural reasons are advisory

# assert_benign_integ_skip_green <cr> <fixture> <reason-fragment> <measured-count>
# <GREEN|ABSTAINED>: the listed Skipped reason never turns the gate red,
# Integration Tests sits under the advisory heading, and the verdict line counts
# only analyzers that measured. A fixture with an abstaining Change Guardian
# Pass reads ABSTAINED.
assert_benign_integ_skip_green() {
  local cr=$1 fixture=$2 reason=$3 measured=$4 verdict=$5 code=0 out advisory_section
  [ "$verdict" = GREEN ] || code=3
  run_body "$cr" "$fixture"
  out=$LAST_OUT
  expect_code "$code" "$LAST_STATUS" "$fixture: a listed Integration Tests Skipped reason must not fail the gate"
  assert_not_contains "$out" "RED" "$fixture: a listed Integration Tests skip must never be reported red"
  assert_contains "$(printf '%s' "$out" | grep "^$verdict")" "- $measured merge-gating analyzers passed and measured something, 1 benign Integration Tests skip" "$fixture: the verdict must count only the analyzers that measured"
  advisory_section=$(printf '%s' "$out" | sed -n '/^advisory/,$p')
  assert_contains "$advisory_section" "Integration Tests: Skipped - $reason" "$fixture: the skip belongs under the advisory heading with its reason"
}

test_iac_integ_skip_is_advisory() {
  # integ-skip-iac.json is captured from a real CDK package CR (ITL-534).
  assert_benign_integ_skip_green CR-5000001 integ-skip-iac.json "Will not test: Code review contains changes to infrastructure-as-code packages." "7 of 8" GREEN
  pass "Integration Tests Skipped for an infrastructure-as-code package => advisory, not red"
}

test_no_pipeline_integ_skip_is_advisory() {
  # integ-skip-no-pipeline.json is captured from a real CR on a package no
  # pipeline builds.
  assert_benign_integ_skip_green CR-5000002 integ-skip-no-pipeline.json "No packages from the CR are built into any pipeline." "5 of 7" ABSTAINED
  pass "Integration Tests Skipped because no pipeline builds the package => advisory, not red"
}

test_no_eligible_pipeline_integ_skip_is_advisory() {
  # integ-skip-no-eligible-pipeline.json is captured from CR-312834222, which
  # CRUX merged with this skip: a pipeline builds the package, but none of its
  # pipelines is eligible to test with ITL.
  assert_benign_integ_skip_green CR-5000006 integ-skip-no-eligible-pipeline.json "Found 1 pipelines that this package builds into, but none were eligible to test with ITL" "6 of 8" ABSTAINED
  pass "Integration Tests Skipped because no pipeline is eligible for ITL => advisory, not red"
}

test_unlisted_integ_skip_is_red() {
  local out
  run_body CR-5000003 integ-skip-unlisted.json
  out=$LAST_OUT
  expect_code 1 "$LAST_STATUS" "an unlisted Integration Tests Skipped reason must still block"
  assert_contains "$out" "RED" "an unlisted skip reason should be red"
  assert_contains "$out" "Integration Tests: Skipped - Will not test: No integration test targets" "the unlisted skip must be named as the blocker"
  pass "Integration Tests Skipped with an unlisted reason => RED, exit 1"
}

test_listed_reason_on_another_analyzer_is_red() {
  # Dry Run Build is Skipped with a listed reason's text, so this proves only the
  # Integration Tests analyzer is ever excused.
  local out blocker_section
  run_body CR-5000005 other-analyzer-skip-listed-reason.json
  out=$LAST_OUT
  expect_code 1 "$LAST_STATUS" "a listed reason on an analyzer other than Integration Tests must still block"
  blocker_section=$(printf '%s' "$out" | sed -n '/^RED:/,/^advisory/p')
  assert_contains "$blocker_section" "Dry Run Build: Skipped" "the other skipped analyzer must be named as the blocker"
  assert_not_contains "$blocker_section" "Integration Tests" "the benign Integration Tests skip stays advisory on the red path"
  pass "a listed skip reason on an analyzer other than Integration Tests => RED, exit 1"
}

test_integ_failure_is_red_even_with_listed_reason_text() {
  # The Fail message deliberately carries a listed reason substring, so this
  # proves only a Skipped status is ever excused.
  local out
  run_body CR-5000004 integ-fail.json
  out=$LAST_OUT
  expect_code 1 "$LAST_STATUS" "an Integration Tests failure must block"
  assert_contains "$out" "RED" "an Integration Tests failure should be red"
  assert_contains "$out" "Integration Tests: Fail" "the failing analyzer must be named as the blocker"
  pass "Integration Tests Fail => RED, exit 1, even when its message matches a listed reason"
}

# ---------------------------------------------------------------------------
# ABSTAINED: a gating Pass that measured nothing is not green

test_abstaining_pass_is_not_green() {
  local out
  run_body CR-6000001 abstained.json
  out=$LAST_OUT
  expect_code 3 "$LAST_STATUS" "a gating Pass that measured nothing must not read as green"
  assert_not_contains "$out" "GREEN" "an abstaining Pass must never be counted green"
  assert_not_contains "$out" "RED" "an abstaining Pass is not a failure"
  assert_contains "$out" "2 of 4 merge-gating analyzers passed and measured something" "the verdict counts only analyzers that measured"
  assert_contains "$out" "Security Code Scanner: Pass - Private package, no permissions to scan" "the scanner abstention is named"
  assert_contains "$out" "Change Guardian: Pass - Analysis was skipped" "the Change Guardian skip is named"
  pass "a gating Pass that measured nothing => ABSTAINED, exit 3, naming each abstainer"
}

test_red_still_wins_over_abstention() {
  local body out status=0
  body=$(jq -c '.analyzers[0].status = "Fail" | .analyzers[0].status_message = "1 build failed"' "$FIXTURES/abstained.json")
  out=$(FM_CR_ANALYZERS_BODY="$body" "$ANALYZERS" CR-6000002 2>&1) || status=$?
  expect_code 1 "$status" "a failing gating analyzer is red even when another abstained"
  assert_contains "$out" "Dry Run Build: Fail - 1 build failed" "the failing analyzer is named as the blocker"
  assert_contains "$out" "passed without measuring anything" "the abstainers are still listed on the red path"
  pass "a gating failure is RED even when another gating Pass abstained"
}

test_advisory_abstention_does_not_block_green() {
  local body out status=0
  body=$(jq -c '.analyzers |= map(select(.partner_id != "Security Code Scanner" and .partner_id != "Change Guardian"))
    | .analyzers += [{"partner_id":"Shepherd","status":"Pass","status_message":"Analysis was skipped because nothing matched.","pass_required_for":[]}]' \
    "$FIXTURES/abstained.json")
  out=$(FM_CR_ANALYZERS_BODY="$body" "$ANALYZERS" CR-6000003 2>&1) || status=$?
  expect_code 0 "$status" "an abstaining analyzer required for nothing does not gate"
  assert_contains "$out" "GREEN" "every gating analyzer measured and passed"
  pass "an abstaining Pass on a non-gating analyzer leaves the gate GREEN"
}

# ---------------------------------------------------------------------------
# UNREADABLE: distinct from green and red

test_no_analyzers_array_is_unreadable_not_green() {
  # A CR body with no analyzers array in either shape must be UNREADABLE, never a
  # false green.
  local out
  run_body CR-4000001 no-analyzers.json
  out=$LAST_OUT
  expect_code 4 "$LAST_STATUS" "a body with no analyzers array should exit with the distinct unreadable code"
  assert_contains "$out" "UNREADABLE" "the verdict must be unreadable"
  assert_not_contains "$out" "GREEN" "an unassessable CR must never be reported green"
  pass "a CR body carrying no analyzers array => UNREADABLE, never a false green"
}

test_mcurl_down_no_fallback_is_unreadable() {
  # Drive the real fetch path: a fake mcurl that fails every fetch, and no
  # builder-mcp fallback CLI on PATH. With neither credential path usable the
  # check must report UNREADABLE (exit 4), matching fm-cr-check.sh's taxonomy -
  # never a false green or red on a CR it could not read.
  local fakebin out status=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/mcurl" <<'SH'
#!/usr/bin/env bash
exit 22
SH
  chmod +x "$fakebin/mcurl"
  out=$(env -i HOME="$HOME" PATH="$fakebin:$BASE_PATH" \
    FM_CR_FALLBACK_BIN="$TMP_ROOT/no-such-builder-cli" \
    "$ANALYZERS" CR-4000002 2>&1) || status=$?
  expect_code 4 "$status" "mcurl down with no fallback should exit with the unreadable code"
  assert_contains "$out" "UNREADABLE" "an unreadable CR must be reported unreadable"
  assert_contains "$out" "builder-mcp fallback is unavailable" "the reason must say the fallback path could not be tried"
  assert_not_contains "$out" "GREEN" "a blind read must never be reported green"
  assert_not_contains "$out" "RED" "a blind read must never be reported red"
  pass "mcurl down and no fallback => UNREADABLE, never a false green or red"
}

test_both_credential_paths_down_is_unreadable() {
  # Both paths present but failing: mcurl fails and a builder-mcp fallback stub is
  # present but exits non-zero. The check must report UNREADABLE naming that both
  # paths were tried, so the captain sees a genuine outage rather than silence.
  local fakebin stub out status=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/mcurl" <<'SH'
#!/usr/bin/env bash
exit 22
SH
  chmod +x "$fakebin/mcurl"
  stub="$TMP_ROOT/failing-builder"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub"
  chmod +x "$stub"
  out=$(env -i HOME="$HOME" PATH="$fakebin:$BASE_PATH" \
    FM_CR_FALLBACK_BIN="$stub" \
    "$ANALYZERS" CR-4000003 2>&1) || status=$?
  expect_code 4 "$status" "both credential paths down should exit with the unreadable code"
  assert_contains "$out" "UNREADABLE" "both-paths-down must be reported unreadable"
  assert_contains "$out" "both credential paths are down" "the reason must say both paths were tried"
  assert_not_contains "$out" "GREEN" "a blind read must never be reported green"
  pass "both credential paths down => UNREADABLE naming both, never a false green"
}

# ---------------------------------------------------------------------------
# Input validation

test_rejects_non_cr_input() {
  local out status=0
  out=$("$ANALYZERS" "not-a-cr" 2>&1) || status=$?
  expect_code 2 "$status" "a non-CR argument should exit 2 (usage)"
  assert_contains "$out" "is not CR-<digits> or a canonical" "the rejection should explain the format requirement"
  pass "a non-CR argument is rejected with a usage exit"
}

# ---------------------------------------------------------------------------

test_all_green_exits_zero
test_fallback_shape_green
test_merge_gating_red_names_the_blocker
test_merge_gating_red_keeps_advisory_out_of_blockers
test_could_not_run_merge_conflict_is_red
test_merge_failed_banner_text_is_red
test_failed_merge_with_auto_merge_cleared_is_red
test_merge_failure_red_keeps_analyzer_blockers
test_merge_failure_ignored_when_not_live
test_advisory_only_is_not_red_with_advisory_line
test_iac_integ_skip_is_advisory
test_no_pipeline_integ_skip_is_advisory
test_no_eligible_pipeline_integ_skip_is_advisory
test_unlisted_integ_skip_is_red
test_listed_reason_on_another_analyzer_is_red
test_integ_failure_is_red_even_with_listed_reason_text
test_abstaining_pass_is_not_green
test_red_still_wins_over_abstention
test_advisory_abstention_does_not_block_green
test_no_analyzers_array_is_unreadable_not_green
test_mcurl_down_no_fallback_is_unreadable
test_both_credential_paths_down_is_unreadable
test_rejects_non_cr_input
