#!/usr/bin/env bash
# Behavior tests for bin/fm-brazil-lib.sh, the per-task Brazil workspace
# contract: detection, workspace build, package add, workspace validation, and
# removal, against the Brazil worktree stand-ins in tests/brazil-helpers.sh:
# `brazil worktree` by default, and the standalone brazil-worktree fallback.
set -u

# shellcheck source=tests/brazil-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/brazil-helpers.sh"
# shellcheck source=bin/fm-brazil-lib.sh
. "$ROOT/bin/fm-brazil-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brazil-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_brazil_fake_tool "$FAKEBIN"
mkdir -p "$TMP_ROOT/standalone-bin" "$TMP_ROOT/both-bin"
fm_brazil_fake_tool "$TMP_ROOT/standalone-bin" standalone
fm_brazil_fake_tool "$TMP_ROOT/both-bin" both
BASE_PATH=$PATH
NO_TOOL_PATH=$(fm_test_base_path_sans "$BASE_PATH" brazil brazil-worktree)
STANDALONE_PATH="$TMP_ROOT/standalone-bin:$BASE_PATH"
BOTH_PATH="$TMP_ROOT/both-bin:$BASE_PATH"
export PATH="$FAKEBIN:$BASE_PATH"
export FM_FAKE_BRAZIL_LOG="$TMP_ROOT/brazil.log"
unset FM_WORKPLACE FM_BRAZIL_FETCH_TIMEOUT FM_BRAZIL_TOOL_TIMEOUT

# new_case <name> <package>...: sets WS (real path) and SHELL_PATH for task "t1".
new_case() {
  local name=$1
  shift
  WS=$(fm_brazil_make_workspace "$TMP_ROOT/$name/ws" "$@")
  SHELL_PATH=$(fm_brazil_shell_path "$WS" t1)
  : > "$FM_FAKE_BRAZIL_LOG"
}

# new_shell <name> <package>...: a case whose task workspace is already built.
new_shell() {
  new_case "$@"
  fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" || fail "fixture: could not build the workspace for $1"
}

# --- detection --------------------------------------------------------------

test_detects_brazil_package_projects() {
  local linked plain
  new_case detect PkgA
  fm_brazil_package_project "$WS/src/PkgA" || fail "the primary package checkout should be a Brazil package"
  assert_equals "$WS" "$FM_BRAZIL_PRIMARY" "detection should report the workspace's real path"
  assert_equals PkgA "$FM_BRAZIL_PACKAGE" "detection should report the package name"

  linked="$TMP_ROOT/detect/linked"
  git -C "$WS/src/PkgA" worktree add -q --detach "$linked"
  fm_brazil_package_project "$linked" || fail "a linked worktree of the package should resolve to its primary"
  assert_equals PkgA "$FM_BRAZIL_PACKAGE" "a linked worktree should report its primary's package"

  rm "$WS/packageInfo"
  fm_brazil_package_project "$WS/src/PkgA" && fail "a package outside any Brazil workspace must not be detected"
  mkdir -p "$WS/.brazil"
  fm_brazil_package_project "$WS/src/PkgA" || fail "a .brazil/ directory should mark the workspace too"

  plain="$TMP_ROOT/detect/plain"
  fm_git_init_commit "$plain"
  fm_brazil_package_project "$plain" && fail "a repository not under <ws>/src must not be detected"
  fm_brazil_package_project "$TMP_ROOT/detect/missing" && fail "a missing path must not be detected"
  pass "detection recognizes a Brazil package checkout, and its linked worktrees, only inside a workspace"
}

# --- workspace build ----------------------------------------------------------

test_build_creates_an_empty_workspace() {
  new_case build PkgA
  fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" || fail "the workspace build should succeed"
  assert_grep "brazil worktree create --name fm-t1 --workspace $WS" "$FM_FAKE_BRAZIL_LOG" \
    "the build should call brazil worktree create for fm-<id>"
  assert_no_grep "--empty" "$FM_FAKE_BRAZIL_LOG" "brazil worktree create has no --empty flag"
  assert_equals "$WS/worktrees/fm-t1" "$SHELL_PATH" "the task workspace should sit in the primary's worktrees/"
  assert_equals "$WS" "$(fm_brazil_shell_primary "$SHELL_PATH")" "the workspace should record its primary"
  [ -d "$SHELL_PATH/src" ] || fail "the workspace should have an empty src/"
  pass "the workspace build runs brazil worktree create and records the primary"
}

test_build_refuses_an_existing_workspace() {
  local out status
  new_case build-exists PkgA
  mkdir -p "$SHELL_PATH"
  out=$(fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an existing workspace path must be refused"
  assert_contains "$out" "brazil worktree delete --name fm-t1 --workspace $WS --force" "the refusal should name the cleanup command"
  assert_no_grep "create --name" "$FM_FAKE_BRAZIL_LOG" "nothing should be created over an existing path"
  pass "the workspace build refuses an existing path instead of reusing it"
}

test_build_refuses_outside_the_contract() {
  local out
  new_case build-bounds PkgA
  out=$(fm_brazil_build_workspace_shell "$WS" "$WS/worktrees/t1" 2>&1) && fail "a workspace not named fm-<id> must be refused"
  assert_contains "$out" "worktrees/fm-<id>" "the refusal should name the expected shape"
  fm_brazil_build_workspace_shell "$WS" "$TMP_ROOT/elsewhere/fm-t1" 2>/dev/null && fail "a workspace outside the primary must be refused"
  fm_brazil_build_workspace_shell "$TMP_ROOT/build-bounds" "$TMP_ROOT/build-bounds/worktrees/fm-t1" 2>/dev/null \
    && fail "a primary that is not a Brazil workspace must be refused"
  assert_no_grep "create --name" "$FM_FAKE_BRAZIL_LOG" "no refused build should reach the tool"
  pass "the workspace build refuses any path that is not <primary>/worktrees/fm-<id> of a Brazil workspace"
}

test_build_requires_the_tool() {
  local out
  new_case build-notool PkgA
  out=$(PATH="$NO_TOOL_PATH" fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" 2>&1) && fail "a build without a worktree tool must fail"
  assert_contains "$out" "toolbox update brazilcli" "the refusal should name the brazilcli install command"
  assert_absent "$SHELL_PATH" "no workspace should exist without the tool"
  pass "the workspace build refuses without brazil worktree or brazil-worktree on PATH"
}

test_build_removes_a_failed_create() {
  local out
  new_case build-partial PkgA
  out=$(FM_FAKE_BRAZIL_PARTIAL=create fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" 2>&1) && fail "a failed create must fail the build"
  assert_contains "$out" "stub: create died" "the tool's own diagnostic should be shown"
  assert_absent "$SHELL_PATH" "the partial workspace should be removed"
  assert_grep "brazil worktree delete --name fm-t1 --workspace $WS --force" "$FM_FAKE_BRAZIL_LOG" "the partial workspace should be removed through the tool"
  pass "a failed create is reported with the tool's output and its partial workspace removed"
}

# --- package add --------------------------------------------------------------

test_add_starts_from_a_fresh_fetch_with_upstream() {
  local tip dest out
  new_shell add PkgA
  tip=$(fm_brazil_advance_origin "$WS" PkgA advanced.txt)
  out=$(fm_brazil_add_package "$SHELL_PATH" PkgA 2>&1) || fail "the add should succeed: $out"
  dest="$SHELL_PATH/src/PkgA"
  assert_equals "$tip" "$(git -C "$dest" rev-parse HEAD)" "the worktree should start at the freshly fetched origin tip"
  assert_equals fm-t1 "$(git -C "$dest" symbolic-ref --short HEAD)" "the worktree should sit on the workspace branch"
  assert_equals origin/mainline "$(git -C "$dest" rev-parse --abbrev-ref '@{upstream}')" "the branch should track origin's default branch"
  assert_equals PkgA "$(fm_brazil_shell_packages "$SHELL_PATH")" "the package should be declared"
  assert_grep "brazil worktree use --name fm-t1 --workspace $WS --package PkgA" "$FM_FAKE_BRAZIL_LOG" "the add should go through the tool"
  assert_contains "$out" "tracking origin/mainline" "the add should report the upstream"
  pass "a package add fetches origin, starts at its tip, and sets the branch's upstream"
}

test_add_sets_upstream_from_a_detached_primary() {
  local dest
  new_shell add-detached PkgA
  git -C "$WS/src/PkgA" checkout -q --detach
  fm_brazil_add_package "$SHELL_PATH" PkgA >/dev/null 2>&1 || fail "the add should succeed from a detached primary"
  dest="$SHELL_PATH/src/PkgA"
  assert_equals origin/mainline "$(git -C "$dest" rev-parse --abbrev-ref '@{upstream}')" \
    "the upstream must be set even when the primary's HEAD tracks nothing"
  pass "a package add sets the upstream itself rather than inheriting the primary's"
}

test_add_honors_an_explicit_base() {
  local seed tip dest
  new_shell add-base PkgA
  seed="$WS.origins/PkgA.seed"
  git -C "$seed" checkout -q -b release
  tip=$(fm_brazil_advance_origin "$WS" PkgA release.txt)
  git -C "$seed" push -q "$WS.origins/PkgA.git" release
  fm_brazil_add_package "$SHELL_PATH" PkgA release >/dev/null 2>&1 || fail "the add should accept a base branch"
  dest="$SHELL_PATH/src/PkgA"
  assert_equals "$tip" "$(git -C "$dest" rev-parse HEAD)" "the worktree should start at the base branch's tip"
  assert_equals origin/release "$(git -C "$dest" rev-parse --abbrev-ref '@{upstream}')" "the branch should track the base branch"
  pass "a package add starts from and tracks an explicit base branch"
}

test_add_is_idempotent() {
  local out before
  new_shell add-again PkgA
  fm_brazil_add_package "$SHELL_PATH" PkgA >/dev/null 2>&1 || fail "the first add should succeed"
  before=$(git -C "$SHELL_PATH/src/PkgA" rev-parse HEAD)
  : > "$FM_FAKE_BRAZIL_LOG"
  out=$(fm_brazil_add_package "$SHELL_PATH" PkgA 2>&1) || fail "adding a package twice should succeed: $out"
  assert_contains "$out" "already added" "the second add should say so"
  assert_no_grep "worktree use" "$FM_FAKE_BRAZIL_LOG" "the second add should not reach the tool"
  assert_equals "$before" "$(git -C "$SHELL_PATH/src/PkgA" rev-parse HEAD)" "the second add should not move the worktree"
  assert_equals 1 "$(fm_brazil_shell_packages "$SHELL_PATH" | grep -cx PkgA)" "the package should be declared once"
  pass "adding a package again is a no-op"
}

test_add_refuses_a_package_the_primary_lacks() {
  local out other before
  new_shell add-missing PkgA
  other=$(fm_brazil_make_workspace "$TMP_ROOT/add-missing/other" PkgB)
  before=$(cat "$WS/packageInfo")
  out=$(fm_brazil_add_package "$SHELL_PATH" PkgB 2>&1) && fail "a package missing from the primary must be refused"
  assert_contains "$out" "not checked out in this task's primary workspace" "the refusal should say why"
  assert_contains "$out" "$other" "the refusal should name the workspace that holds the package"
  assert_contains "$out" "needs-decision" "the refusal should route cross-workspace work to firstmate"
  assert_no_grep "worktree use" "$FM_FAKE_BRAZIL_LOG" "the tool must never be asked for a package the primary lacks"
  assert_equals "$before" "$(cat "$WS/packageInfo")" "the primary's packageInfo must be untouched"
  assert_absent "$SHELL_PATH/src/PkgB" "no worktree should be created"
  pass "a package the primary lacks is refused before the tool can touch the primary"
}

test_add_refuses_bad_input() {
  new_shell add-bad PkgA
  fm_brazil_add_package "$SHELL_PATH" '../PkgA' 2>/dev/null && fail "a path-like package name must be refused"
  fm_brazil_add_package "$SHELL_PATH" '' 2>/dev/null && fail "an empty package name must be refused"
  mkdir -p "$SHELL_PATH/src/PkgA"
  : > "$SHELL_PATH/src/PkgA/stray"
  fm_brazil_add_package "$SHELL_PATH" PkgA 2>/dev/null && fail "a non-worktree directory must not be overwritten"
  [ -f "$SHELL_PATH/src/PkgA/stray" ] || fail "the existing directory must be left alone"
  fm_brazil_add_package "$TMP_ROOT/add-bad" PkgA 2>/dev/null && fail "a directory without .fm-primary must be refused"
  assert_no_grep "worktree use" "$FM_FAKE_BRAZIL_LOG" "no refused add should reach the tool"
  pass "a package add refuses bad names, foreign directories, and a missing workspace marker"
}

test_add_refuses_a_leftover_branch() {
  local out
  new_shell add-branch PkgA
  git -C "$WS/src/PkgA" branch fm-t1
  out=$(fm_brazil_add_package "$SHELL_PATH" PkgA 2>&1) && fail "an existing fm-<id> branch must be refused"
  assert_contains "$out" "branch 'fm-t1' already exists" "the refusal should name the branch"
  assert_no_grep "worktree use" "$FM_FAKE_BRAZIL_LOG" "the tool must not reuse the leftover branch"
  pass "a leftover fm-<id> branch is refused, because the tool would reuse and later delete it"
}

test_add_refuses_a_stale_base() {
  local out
  new_shell add-stale PkgA
  git -C "$WS/src/PkgA" remote set-url origin "$TMP_ROOT/add-stale/gone.git"
  out=$(fm_brazil_add_package "$SHELL_PATH" PkgA 2>&1) && fail "an unreachable origin must refuse the add"
  assert_contains "$out" "refusing to start the worktree from a stale base" "the refusal should say why"
  assert_contains "$out" "mwinit" "the refusal should name the usual fix"
  assert_no_grep "worktree use" "$FM_FAKE_BRAZIL_LOG" "nothing should be added from a stale base"

  git -C "$WS/src/PkgA" remote remove origin
  out=$(fm_brazil_add_package "$SHELL_PATH" PkgA 2>&1) && fail "a package with no origin must be refused"
  assert_contains "$out" "has no origin remote" "the no-origin refusal should say so"
  pass "a package add refuses when origin cannot be fetched or does not exist"
}

test_add_bounds_a_hung_fetch() {
  local out status start elapsed
  new_shell add-hang PkgA
  cat > "$FAKEBIN/git" <<SH
#!/usr/bin/env bash
case " \$* " in *" fetch "*) sleep 30 ;; esac
exec $(command -v git) "\$@"
SH
  chmod +x "$FAKEBIN/git"
  start=$(date +%s)
  out=$(FM_BRAZIL_FETCH_TIMEOUT=1 fm_brazil_add_package "$SHELL_PATH" PkgA base-free 2>&1)
  status=$?
  elapsed=$(( $(date +%s) - start ))
  rm -f "$FAKEBIN/git"
  hash -r
  [ "$status" -ne 0 ] || fail "a hung fetch must refuse the add"
  [ "$elapsed" -lt 20 ] || fail "the fetch bound did not hold (${elapsed}s)"
  assert_contains "$out" "timed out after 1s" "the refusal should name the bound"
  out=$(FM_BRAZIL_FETCH_TIMEOUT=0 fm_brazil_add_package "$SHELL_PATH" PkgA 2>&1) && fail "a zero fetch bound must be refused"
  assert_contains "$out" "positive number of seconds" "an invalid bound should be named"
  pass "a hung fetch is bounded and an invalid bound is refused"
}

test_add_refuses_a_bogus_tool_result() {
  local out
  new_shell add-bogus PkgA
  out=$(FM_FAKE_BRAZIL_BOGUS_ADD=1 fm_brazil_add_package "$SHELL_PATH" PkgA 2>&1) && fail "a non-worktree result must be refused"
  assert_contains "$out" "is not a worktree of" "the refusal should say why"
  assert_equals "" "$(fm_brazil_shell_packages "$SHELL_PATH")" "nothing should be declared before the worktree is proven"
  pass "a tool result that is not a real worktree is refused before any reset"
}

test_add_surfaces_tool_failure() {
  local out
  new_shell add-toolfail PkgA
  out=$(FM_FAKE_BRAZIL_FAIL=use fm_brazil_add_package "$SHELL_PATH" PkgA 2>&1) && fail "a failed add must fail the add"
  assert_contains "$out" "stub: forced use failure" "the tool's own diagnostic should be shown"
  pass "a failed add is reported with the tool's output"
}

# --- validation ---------------------------------------------------------------

test_validate_accepts_an_intact_workspace() {
  new_shell validate PkgA PkgB
  fm_brazil_add_package "$SHELL_PATH" PkgA >/dev/null 2>&1 || fail "fixture: add PkgA"
  fm_brazil_add_package "$SHELL_PATH" PkgB >/dev/null 2>&1 || fail "fixture: add PkgB"
  fm_brazil_validate_workspace_shell "$SHELL_PATH" "$SHELL_PATH/src/PkgA" || fail "an intact workspace should validate"
  assert_equals "$WS" "$FM_BRAZIL_PRIMARY" "validation should report the primary"
  assert_equals PkgA "$FM_BRAZIL_PACKAGE" "validation should report the worktree's package"
  pass "an intact workspace validates and names the worktree's package"
}

test_validate_rejects_a_damaged_workspace() {
  local out
  new_shell validate-bad PkgA PkgB
  fm_brazil_add_package "$SHELL_PATH" PkgA >/dev/null 2>&1 || fail "fixture: add PkgA"
  fm_brazil_add_package "$SHELL_PATH" PkgB >/dev/null 2>&1 || fail "fixture: add PkgB"

  out=$(fm_brazil_validate_workspace_shell "$SHELL_PATH" "$WS/src/PkgA" 2>&1) && fail "a worktree outside the workspace must be refused"
  assert_contains "$out" "is not a declared package" "an undeclared worktree should be named"

  git -C "$WS/src/PkgB" worktree remove --force "$SHELL_PATH/src/PkgB"
  out=$(fm_brazil_validate_workspace_shell "$SHELL_PATH" "$SHELL_PATH/src/PkgA" 2>&1) && fail "a missing declared package must be refused"
  assert_contains "$out" "declares package 'PkgB'" "the missing package should be named"

  printf '%s\n' "$TMP_ROOT" > "$SHELL_PATH/.fm-primary"
  out=$(fm_brazil_validate_workspace_shell "$SHELL_PATH" "$SHELL_PATH/src/PkgA" 2>&1) && fail "a workspace recording another primary must be refused"
  assert_contains "$out" "not a task workspace of its recorded primary" "a foreign primary should be named"

  rm "$SHELL_PATH/.fm-primary"
  out=$(fm_brazil_validate_workspace_shell "$SHELL_PATH" "$SHELL_PATH/src/PkgA" 2>&1) && fail "a workspace without its marker must be refused"
  assert_contains "$out" "no readable .fm-primary" "a missing marker should be named"

  out=$(fm_brazil_validate_workspace_shell "$TMP_ROOT/validate-bad/none" "$SHELL_PATH/src/PkgA" 2>&1) && fail "a missing workspace must be refused"
  assert_contains "$out" "is missing" "a missing workspace should be named"
  pass "validation refuses a workspace that lost a package, its marker, or its primary"
}

# --- removal ------------------------------------------------------------------

test_remove_goes_through_the_tool() {
  new_shell remove PkgA
  fm_brazil_add_package "$SHELL_PATH" PkgA >/dev/null 2>&1 || fail "fixture: add PkgA"
  fm_brazil_remove_workspace_shell "$WS" "$SHELL_PATH" || fail "the removal should succeed"
  assert_grep "brazil worktree delete --name fm-t1 --workspace $WS --force" "$FM_FAKE_BRAZIL_LOG" "the removal should go through the tool"
  assert_absent "$SHELL_PATH" "the workspace should be gone"
  git -C "$WS/src/PkgA" show-ref --verify --quiet refs/heads/fm-t1 && fail "the workspace branch should be gone"
  fm_brazil_remove_workspace_shell "$WS" "$SHELL_PATH" || fail "removing a workspace already gone should succeed"
  pass "the removal deletes the workspace and its branch through brazil worktree delete"
}

test_remove_refuses_unbounded_paths() {
  new_shell remove-bounds PkgA
  fm_brazil_remove_workspace_shell "$WS" "$WS" 2>/dev/null && fail "the primary itself must never be removed"
  fm_brazil_remove_workspace_shell "$WS" "$WS/worktrees/retrace-brazil" 2>/dev/null && fail "a workspace not named fm-<id> must be refused"
  fm_brazil_remove_workspace_shell "$WS" "$WS/worktrees/../worktrees/fm-t1" 2>/dev/null && fail "a path stepping through .. must be refused"
  fm_brazil_remove_workspace_shell "$WS" "$TMP_ROOT/fm-t1" 2>/dev/null && fail "a path outside the primary must be refused"
  fm_brazil_remove_workspace_shell "relative" "relative/worktrees/fm-t1" 2>/dev/null && fail "a relative primary must be refused"
  assert_no_grep "delete --name" "$FM_FAKE_BRAZIL_LOG" "no refused removal should reach the tool"
  [ -d "$SHELL_PATH" ] || fail "the task workspace must survive refused removals"
  pass "the removal refuses every path that is not <primary>/worktrees/fm-<id>"
}

test_remove_reports_what_survives() {
  local out
  new_shell remove-left PkgA
  out=$(FM_FAKE_BRAZIL_KEEP=1 fm_brazil_remove_workspace_shell "$WS" "$SHELL_PATH" 2>&1) && fail "a workspace that survives removal must fail it"
  assert_contains "$out" "still exists after brazil worktree delete" "the survivor should be named"
  out=$(FM_FAKE_BRAZIL_FAIL=delete fm_brazil_remove_workspace_shell "$WS" "$SHELL_PATH" 2>&1) && fail "a failed delete must fail the removal"
  assert_contains "$out" "stub: forced delete failure" "the tool's own diagnostic should be shown"
  [ -d "$SHELL_PATH" ] || fail "a failed removal must not fall back to deleting the workspace by hand"
  pass "a failed or incomplete removal is reported and leaves the workspace for a retry"
}

test_remove_forces_past_unpushed_work() {
  new_shell remove-unpushed PkgA
  fm_brazil_add_package "$SHELL_PATH" PkgA >/dev/null 2>&1 || fail "fixture: add PkgA"
  git -C "$SHELL_PATH/src/PkgA" -c user.name=t -c user.email=t@t commit -q --allow-empty -m landed-by-review
  [ -n "$(git -C "$SHELL_PATH/src/PkgA" log --oneline '@{u}..HEAD')" ] || fail "fixture: the branch should carry an unpushed commit"
  fm_brazil_remove_workspace_shell "$WS" "$SHELL_PATH" || fail "the removal should not stop at work teardown already proved landed"
  assert_absent "$SHELL_PATH" "the workspace should be gone"
  pass "the removal passes --force, because teardown owns the landed-work check"
}

# --- standalone fallback ----------------------------------------------------

test_standalone_tool_when_brazil_lacks_worktree() {
  local out
  new_case standalone PkgA
  PATH="$STANDALONE_PATH" fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" || fail "the standalone build should succeed"
  assert_grep "brazil-worktree create --name fm-t1 --workspace $WS --empty" "$FM_FAKE_BRAZIL_LOG" \
    "the build should fall back to brazil-worktree create --empty"
  [ -d "$SHELL_PATH/src" ] || fail "the standalone workspace should have src/"
  out=$(PATH="$STANDALONE_PATH" fm_brazil_add_package "$SHELL_PATH" PkgA 2>&1) || fail "the standalone add should succeed: $out"
  assert_grep "brazil-worktree addPackage --name fm-t1 --workspace $WS --package PkgA" "$FM_FAKE_BRAZIL_LOG" \
    "the add should fall back to brazil-worktree addPackage"
  out=$(PATH="$STANDALONE_PATH" fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" 2>&1) && fail "an existing workspace must be refused"
  assert_contains "$out" "brazil-worktree remove --name fm-t1 --workspace $WS" "the refusal should name the standalone cleanup command"
  PATH="$STANDALONE_PATH" fm_brazil_remove_workspace_shell "$WS" "$SHELL_PATH" || fail "the standalone removal should succeed"
  assert_grep "brazil-worktree remove --name fm-t1 --workspace $WS" "$FM_FAKE_BRAZIL_LOG" \
    "the removal should fall back to brazil-worktree remove"
  assert_absent "$SHELL_PATH" "the workspace should be gone"
  assert_no_grep "brazil worktree create" "$FM_FAKE_BRAZIL_LOG" "the build should not reach the missing subcommand"
  assert_no_grep "brazil worktree use" "$FM_FAKE_BRAZIL_LOG" "the add should not reach the missing subcommand"
  assert_no_grep "brazil worktree delete" "$FM_FAKE_BRAZIL_LOG" "the removal should not reach the missing subcommand"
  pass "without brazil worktree, build, add, and removal use the standalone brazil-worktree"
}

test_brazil_worktree_preferred_over_standalone() {
  new_case both PkgA
  PATH="$BOTH_PATH" fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" || fail "the build should succeed"
  PATH="$BOTH_PATH" fm_brazil_add_package "$SHELL_PATH" PkgA >/dev/null 2>&1 || fail "the add should succeed"
  PATH="$BOTH_PATH" fm_brazil_remove_workspace_shell "$WS" "$SHELL_PATH" || fail "the removal should succeed"
  assert_grep "brazil worktree create --name fm-t1" "$FM_FAKE_BRAZIL_LOG" "the build should use brazil worktree"
  assert_grep "brazil worktree use --name fm-t1" "$FM_FAKE_BRAZIL_LOG" "the add should use brazil worktree"
  assert_grep "brazil worktree delete --name fm-t1" "$FM_FAKE_BRAZIL_LOG" "the removal should use brazil worktree"
  assert_no_grep "brazil-worktree" "$FM_FAKE_BRAZIL_LOG" "the standalone tool should not be called when brazil worktree works"
  pass "brazil worktree is preferred whenever brazil has the subcommand"
}

test_launch_section_names_the_workspace() {
  local out
  out=$(fm_brazil_launch_section /ws/worktrees/fm-t1 PkgA /fm)
  assert_contains "$out" "# Brazil workspace" "the section should have its heading"
  assert_contains "$out" "/ws/worktrees/fm-t1/src/PkgA" "the section should name the package worktree"
  assert_contains "$out" "primary workspace \`/ws\`" "the section should name the primary"
  assert_contains "$out" "branch \`fm-t1\`" "the section should name the starting branch"
  assert_contains "$out" "/fm/bin/fm-worktree-add.sh <Package>" "the section should name the declare command"
  pass "the launch section names the workspace, the package worktree, and the declare command"
}

test_detects_brazil_package_projects
test_build_creates_an_empty_workspace
test_build_refuses_an_existing_workspace
test_build_refuses_outside_the_contract
test_build_requires_the_tool
test_build_removes_a_failed_create
test_add_starts_from_a_fresh_fetch_with_upstream
test_add_sets_upstream_from_a_detached_primary
test_add_honors_an_explicit_base
test_add_is_idempotent
test_add_refuses_a_package_the_primary_lacks
test_add_refuses_bad_input
test_add_refuses_a_leftover_branch
test_add_refuses_a_stale_base
test_add_bounds_a_hung_fetch
test_add_refuses_a_bogus_tool_result
test_add_surfaces_tool_failure
test_validate_accepts_an_intact_workspace
test_validate_rejects_a_damaged_workspace
test_remove_goes_through_the_tool
test_remove_refuses_unbounded_paths
test_remove_reports_what_survives
test_remove_forces_past_unpushed_work
test_standalone_tool_when_brazil_lacks_worktree
test_brazil_worktree_preferred_over_standalone
test_launch_section_names_the_workspace
