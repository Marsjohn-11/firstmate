#!/usr/bin/env bash
# Contract: no-mistakes runs the deterministic complete-suite gate, whose plan
# is an exact disjoint cover of real test discovery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"
GATE="$ROOT/bin/fm-no-mistakes-test.sh"

test_nm_configures_complete_suite_gate() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts val.to_s
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  [ "$val" = "bin/fm-no-mistakes-test.sh" ] \
    || fail "commands.test must invoke the complete-suite gate, got: ${val:-<empty>}"
  pass "no-mistakes configures the deterministic complete-suite gate"
}

test_plan_is_complete_and_disjoint() {
  local tmp out
  tmp=$(fm_test_tmproot fm-nm-test-plan)
  "$GATE" --list-plan >"$tmp/plan"
  out=$("$GATE" --check-plan "$tmp/plan") \
    || fail "generated no-mistakes test plan did not validate"
  assert_contains "$out" "FM_TEST_PLAN ok total=" "plan validation summary"
  pass "no-mistakes test plan is a complete disjoint cover"
}

test_missing_target_fails_by_name() {
  local tmp missing rc=0
  tmp=$(fm_test_tmproot fm-nm-test-missing)
  "$GATE" --list-plan >"$tmp/plan"
  missing=$(sed -n '1s/^[^\t]*\t//p' "$tmp/plan")
  sed '1d' "$tmp/plan" >"$tmp/missing"
  "$GATE" --check-plan "$tmp/missing" >"$tmp/out" 2>"$tmp/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a test assigned to zero lanes was accepted"
  assert_contains "$(cat "$tmp/err")" "discovered files assigned to zero lanes" \
    "zero-lane refusal heading"
  assert_contains "$(cat "$tmp/err")" "$missing" "zero-lane refusal file name"
  pass "a test assigned to zero lanes fails loudly by name"
}

test_duplicate_target_fails_by_name() {
  local tmp duplicate rc=0
  tmp=$(fm_test_tmproot fm-nm-test-duplicate)
  "$GATE" --list-plan >"$tmp/plan"
  duplicate=$(sed -n '1s/^[^\t]*\t//p' "$tmp/plan")
  cp "$tmp/plan" "$tmp/duplicate"
  sed -n '1p' "$tmp/plan" >>"$tmp/duplicate"
  "$GATE" --check-plan "$tmp/duplicate" >"$tmp/out" 2>"$tmp/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a test assigned to multiple lanes was accepted"
  assert_contains "$(cat "$tmp/err")" "files assigned to multiple lanes" \
    "duplicate-lane refusal heading"
  assert_contains "$(cat "$tmp/err")" "$duplicate" "duplicate-lane refusal file name"
  pass "a test assigned to multiple lanes fails loudly by name"
}

test_nm_configures_complete_suite_gate
test_plan_is_complete_and_disjoint
test_missing_target_fails_by_name
test_duplicate_target_fails_by_name
