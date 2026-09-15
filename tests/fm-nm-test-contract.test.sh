#!/usr/bin/env bash
# Contract: no-mistakes runs the deterministic complete-suite gate, whose plan
# is an exact disjoint cover of real test discovery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"
GATE="$ROOT/bin/fm-no-mistakes-test.sh"
LANE_GUARD="$ROOT/bin/fm-test-lane-guard.py"

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

test_abandoned_lane_process_group_is_reaped() {
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to verify abandoned lane cleanup"
  local tmp group_pid helper_pid owner_pid owner_start watcher_pid attempt
  tmp=$(fm_test_tmproot fm-nm-test-reaper)
  cat >"$tmp/lane.sh" <<'SH'
#!/usr/bin/env bash
python3 - "$1" <<'PY' &
import subprocess
import sys

helper = subprocess.Popen(["sleep", "30"], start_new_session=True)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{helper.pid}\n")
helper.wait()
PY
wait
SH
  chmod +x "$tmp/lane.sh"
  python3 "$LANE_GUARD" run "$tmp/lane.sh" "$tmp/helper.pid" &
  group_pid=$!
  printf '%s\n' "$group_pid" >"$tmp/groups"
  attempt=0
  while [ ! -s "$tmp/helper.pid" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.02
    attempt=$((attempt + 1))
  done
  assert_present "$tmp/helper.pid" "lane fixture did not publish its helper pid"
  helper_pid=$(cat "$tmp/helper.pid")

  sleep 0.3 &
  owner_pid=$!
  owner_start=$(ps -p "$owner_pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  python3 "$LANE_GUARD" watch "$owner_pid" "$owner_start" "$tmp/groups" &
  watcher_pid=$!
  wait "$owner_pid"
  wait "$watcher_pid"

  if kill -0 "$helper_pid" 2>/dev/null; then
    python3 "$LANE_GUARD" reap "$tmp/groups" >/dev/null 2>&1 || true
    wait "$group_pid" 2>/dev/null || true
    fail "watchdog left a lane helper alive after its owner disappeared"
  fi
  wait "$group_pid" 2>/dev/null || true
  pass "an independent watchdog reaps nested groups under an abandoned lane"
}

test_nm_configures_complete_suite_gate
test_plan_is_complete_and_disjoint
test_missing_target_fails_by_name
test_duplicate_target_fails_by_name
test_abandoned_lane_process_group_is_reaped
