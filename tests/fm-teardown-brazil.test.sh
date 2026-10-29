#!/usr/bin/env bash
# Behavior tests for fm-teardown on a Brazil task (project_kind=brazil): every
# package the task declared in its own Brazil workspace faces the landed-work
# check, and the workspace is removed with brazil-worktree rather than returned
# to a Treehouse pool. bin/fm-brazil-lib.sh owns the workspace contract.
set -u

# shellcheck source=tests/brazil-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/brazil-helpers.sh"
# shellcheck source=bin/fm-brazil-lib.sh
. "$ROOT/bin/fm-brazil-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-brazil)
unset FM_WORKPLACE FM_BRAZIL_FETCH_TIMEOUT FM_BRAZIL_TOOL_TIMEOUT
ID=task-x1

# make_case <name> <kind> <mode>: a task whose Brazil workspace declares PkgA
# (its worktree=) and PkgB, both on the workspace branch with the worker's ship
# branch checked out in PkgA. Sets CASE_DIR, WS, SHELL_PATH, WT, and OTHER.
make_case() {
  local name=$1 kind=$2 mode=$3 fakebin
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR/state" "$CASE_DIR/data/$ID" "$CASE_DIR/config"
  touch "$CASE_DIR/state/.last-watcher-beat" "$CASE_DIR/brazil.log"
  fakebin=$(fm_fakebin "$CASE_DIR")
  fm_brazil_fake_tool "$fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/treehouse.log"\nexit 0\n' "$CASE_DIR" > "$fakebin/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  printf '#!/usr/bin/env bash\necho "error: pull request not found" >&2\nexit 1\n' > "$fakebin/gh"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/no-mistakes"
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/no-mistakes"

  WS=$(fm_brazil_make_workspace "$CASE_DIR/ws" PkgA PkgB)
  SHELL_PATH=$(fm_brazil_shell_path "$WS" "$ID")
  WT="$SHELL_PATH/src/PkgA"
  OTHER="$SHELL_PATH/src/PkgB"
  PATH="$fakebin:$PATH" fm_brazil_build_workspace_shell "$WS" "$SHELL_PATH" || fail "fixture: build the workspace"
  PATH="$fakebin:$PATH" fm_brazil_add_package "$SHELL_PATH" PkgA >/dev/null 2>&1 || fail "fixture: add PkgA"
  PATH="$fakebin:$PATH" fm_brazil_add_package "$SHELL_PATH" PkgB >/dev/null 2>&1 || fail "fixture: add PkgB"
  git -C "$WT" checkout -q -b "fm/$ID"
  [ "$kind" != scout ] || : > "$CASE_DIR/data/$ID/report.md"
  fm_write_meta "$CASE_DIR/state/$ID.meta" \
    "window=firstmate:fm-$ID" \
    "endpoint_task_id=$ID" \
    "worktree=$WT" \
    "project=$WS/src/PkgA" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=teardown-brazil-$ID" \
    "project_kind=brazil" \
    "workspace_shell=$SHELL_PATH"
  # A scout's report passed the captain-call completion gate.
  [ "$kind" != scout ] || printf '%s\n' 'decisions_reviewed=1' >> "$CASE_DIR/state/$ID.meta"
}

run_teardown() {
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$CASE_DIR/state" \
  FM_DATA_OVERRIDE="$CASE_DIR/data" \
  FM_CONFIG_OVERRIDE="$CASE_DIR/config" \
  FM_FAKE_BRAZIL_LOG="$CASE_DIR/brazil.log" \
  PATH="$CASE_DIR/fakebin:$PATH" \
    "$TEARDOWN" "$ID" "$@" > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
}

commit_in() {  # <worktree> <file>
  printf '%s\n' "$2" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "add $2"
}

assert_workspace_removed() {
  assert_grep "remove --name fm-$ID --workspace $WS" "$CASE_DIR/brazil.log" "$1: the workspace should be removed through brazil-worktree"
  assert_absent "$SHELL_PATH" "$1: the workspace should be gone"
  assert_absent "$CASE_DIR/state/$ID.meta" "$1: the task record should be removed"
  assert_absent "$CASE_DIR/treehouse.log" "$1: a Brazil task must never be returned to a Treehouse pool"
}

assert_refused_intact() {
  [ "$1" -ne 0 ] || fail "$2: teardown must refuse"
  assert_present "$SHELL_PATH" "$2: the workspace must be kept"
  assert_present "$CASE_DIR/state/$ID.meta" "$2: the task record must be kept"
  assert_no_grep "remove --name" "$CASE_DIR/brazil.log" "$2: nothing may be removed"
}

test_landed_workspace_is_removed() {
  local status
  make_case landed ship direct-PR
  commit_in "$WT" pushed.txt
  git -C "$WT" push -q origin "fm/$ID"
  run_teardown
  status=$?
  expect_code 0 "$status" "a landed Brazil task should tear down: $(cat "$CASE_DIR/stderr")"
  assert_workspace_removed "landed"
  git -C "$WS/src/PkgA" show-ref --verify --quiet "refs/heads/fm/$ID" && fail "the worker's ship branch should be dropped"
  git -C "$WS/src/PkgB" show-ref --verify --quiet "refs/heads/fm-$ID" && fail "the declared package's workspace branch should be gone"
  pass "a Brazil task whose packages all landed is removed with brazil-worktree, with its branches"
}

test_unlanded_declared_package_refuses() {
  local status
  make_case unlanded ship direct-PR
  commit_in "$OTHER" stranded.txt
  run_teardown
  status=$?
  assert_refused_intact "$status" "unlanded declared package"
  assert_grep "REFUSED: worktree $OTHER has work not on any remote and not landed." "$CASE_DIR/stderr" \
    "the refusal should come from the shared landed-work check on that package"
  assert_grep "declared Brazil package PkgB" "$CASE_DIR/stderr" "the refusal should name the package"
  pass "an unpushed commit in a declared package refuses teardown and keeps everything"
}

test_dirty_declared_package_refuses() {
  local status
  make_case dirty ship direct-PR
  printf 'edit\n' >> "$OTHER/Config"
  run_teardown
  status=$?
  assert_refused_intact "$status" "dirty declared package"
  assert_grep "REFUSED: worktree $OTHER has uncommitted changes." "$CASE_DIR/stderr" "the refusal should name the dirty package"
  pass "an uncommitted change in a declared package refuses teardown"
}

test_declared_package_content_landed_passes() {
  local status
  make_case content ship direct-PR
  commit_in "$OTHER" squashed.txt
  fm_brazil_advance_origin "$WS" PkgB squashed.txt >/dev/null
  run_teardown
  status=$?
  expect_code 0 "$status" "a declared package whose content is on its origin should pass: $(cat "$CASE_DIR/stderr")"
  assert_workspace_removed "content landed"
  pass "a declared package whose change landed by content, not ancestry, passes"
}

test_local_only_declared_package_merged_locally_passes() {
  local status
  make_case local-only ship local-only
  commit_in "$OTHER" merged.txt
  git -C "$WS/src/PkgB" merge -q --ff-only "fm-$ID"
  run_teardown
  status=$?
  expect_code 0 "$status" "a local-only package merged into its local default branch should pass: $(cat "$CASE_DIR/stderr")"
  assert_workspace_removed "local-only"
  pass "a local-only declared package merged into its own local default branch passes"
}

test_force_discards_unlanded_packages() {
  local status
  make_case force ship direct-PR
  commit_in "$OTHER" discarded.txt
  printf 'edit\n' >> "$WT/Config"
  run_teardown --force
  status=$?
  expect_code 0 "$status" "--force should discard: $(cat "$CASE_DIR/stderr")"
  assert_workspace_removed "forced"
  pass "--force removes a Brazil workspace with unlanded work"
}

test_scout_workspace_is_scratch() {
  local status
  make_case scout scout ''
  printf 'scratch\n' > "$OTHER/scratch.txt"
  run_teardown
  status=$?
  expect_code 0 "$status" "a scout's workspace is scratch: $(cat "$CASE_DIR/stderr")"
  assert_workspace_removed "scout"
  pass "a Brazil scout's workspace is removed as scratch once its report exists"
}

test_failed_removal_keeps_the_records() {
  local status
  make_case keep ship direct-PR
  git -C "$WT" push -q origin "fm/$ID"
  FM_FAKE_BRAZIL_KEEP=1 run_teardown
  status=$?
  [ "$status" -ne 0 ] || fail "a workspace that survives removal must fail teardown"
  assert_grep "still exists after brazil-worktree remove" "$CASE_DIR/stderr" "the survivor should be named"
  assert_grep "teardown aborted with its records intact" "$CASE_DIR/stderr" "teardown should say it kept the records"
  assert_present "$CASE_DIR/state/$ID.meta" "the task record must be kept for a retry"
  assert_absent "$CASE_DIR/treehouse.log" "a failed removal must not fall back to a Treehouse return"
  pass "a removal that leaves the workspace behind aborts teardown with the records intact"
}

test_landed_workspace_is_removed
test_unlanded_declared_package_refuses
test_dirty_declared_package_refuses
test_declared_package_content_landed_passes
test_local_only_declared_package_merged_locally_passes
test_force_discards_unlanded_packages
test_scout_workspace_is_scratch
test_failed_removal_keeps_the_records
