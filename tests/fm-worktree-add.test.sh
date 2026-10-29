#!/usr/bin/env bash
# Behavior tests for bin/fm-worktree-add.sh, the worker's declare-a-package
# command: it finds the task's Brazil workspace from the current directory and
# adds or lists packages (bin/fm-brazil-lib.sh owns the add itself).
set -u

# shellcheck source=tests/brazil-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/brazil-helpers.sh"
# shellcheck source=bin/fm-brazil-lib.sh
. "$ROOT/bin/fm-brazil-lib.sh"

ADD="$ROOT/bin/fm-worktree-add.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-add)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_brazil_fake_tool "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"
unset FM_WORKPLACE FM_BRAZIL_FETCH_TIMEOUT FM_BRAZIL_TOOL_TIMEOUT

WS=$(fm_brazil_make_workspace "$TMP_ROOT/ws" PkgA PkgB)
SHELL_PATH=$(fm_brazil_shell_path "$WS" t1)
fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" || fail "fixture: could not build the task workspace"
fm_brazil_add_package "$SHELL_PATH" PkgA >/dev/null 2>&1 || fail "fixture: could not add the project's package"

test_adds_a_package_from_inside_a_package_worktree() {
  local out status
  out=$(cd "$SHELL_PATH/src/PkgA" && "$ADD" PkgB 2>&1)
  status=$?
  expect_code 0 "$status" "declaring a package from inside a package worktree should succeed: $out"
  assert_contains "$out" "added: PkgB -> $SHELL_PATH/src/PkgB" "the add should report the new worktree"
  assert_equals fm-t1 "$(git -C "$SHELL_PATH/src/PkgB" symbolic-ref --short HEAD)" "the package should sit on the workspace branch"
  assert_equals "PkgA
PkgB" "$(cd "$SHELL_PATH" && "$ADD" --list)" "--list should print every declared package in order"
  out=$(cd "$SHELL_PATH/src" && "$ADD" PkgB 2>&1) || fail "declaring a package again should succeed: $out"
  assert_contains "$out" "already added" "a second declaration should be a no-op"
  pass "fm-worktree-add finds the workspace from any directory in it, adds, and lists packages"
}

test_refuses_outside_a_task_workspace() {
  local out status
  out=$(cd "$WS/src/PkgA" && "$ADD" PkgB 2>&1)
  status=$?
  expect_code 1 "$status" "running outside a task workspace should fail"
  assert_contains "$out" "not inside a task Brazil workspace" "the refusal should say why"
  pass "fm-worktree-add refuses outside a task workspace, including the primary's own checkout"
}

test_refuses_a_package_the_primary_lacks() {
  local out
  out=$(cd "$SHELL_PATH" && "$ADD" PkgC 2>&1) && fail "a package the primary lacks must be refused"
  assert_contains "$out" "not checked out in this task's primary workspace" "the refusal should say why"
  assert_absent "$SHELL_PATH/src/PkgC" "no worktree should be created"
  pass "fm-worktree-add refuses a package the primary workspace does not hold"
}

test_usage_errors() {
  local out status
  out=$(cd "$SHELL_PATH" && "$ADD" 2>&1)
  status=$?
  expect_code 2 "$status" "no package should be a usage error"
  assert_contains "$out" "usage: fm-worktree-add.sh" "the usage should be printed"
  (cd "$SHELL_PATH" && "$ADD" PkgA PkgB >/dev/null 2>&1)
  expect_code 2 "$?" "two packages should be a usage error"
  (cd "$SHELL_PATH" && "$ADD" --bogus >/dev/null 2>&1)
  expect_code 2 "$?" "an unknown flag should be a usage error"
  "$ADD" --help >/dev/null 2>&1
  expect_code 2 "$?" "--help should print the usage"
  pass "fm-worktree-add reports usage errors"
}

test_adds_a_package_from_inside_a_package_worktree
test_refuses_outside_a_task_workspace
test_refuses_a_package_the_primary_lacks
test_usage_errors
