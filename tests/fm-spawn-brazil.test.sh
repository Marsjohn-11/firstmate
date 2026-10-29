#!/usr/bin/env bash
# Behavior tests for fm-spawn on a Brazil package: a fresh ship or scout gets
# its own Brazil workspace instead of a Treehouse slot (bin/fm-brazil-lib.sh
# owns the contract), and the spawn refuses or cleans up rather than launching
# a worker on a stale, shared, or half-built workspace. A relaunch through
# bin/fm-control.sh reuses an intact workspace and refuses a damaged one.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/brazil-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/brazil-helpers.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-brazil)
unset FM_WORKPLACE FM_BRAZIL_FETCH_TIMEOUT FM_BRAZIL_TOOL_TIMEOUT

# make_case <name> <id>: sets CASE_DIR, HOME_DIR, WS (real path), PROJECT_DIR
# (the primary's PkgA checkout), FAKEBIN_DIR, SHELL_PATH, and WT_PATH.
make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  fm_brazil_fake_tool "$FAKEBIN_DIR"
  # These cases assert placement and records, not how long a pane is polled.
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$id"
  WS=$(fm_brazil_make_workspace "$CASE_DIR/ws" PkgA)
  PROJECT_DIR="$WS/src/PkgA"
  SHELL_PATH="$WS/worktrees/fm-$id"
  WT_PATH="$SHELL_PATH/src/PkgA"
}

run_spawn() {
  FM_FAKE_BRAZIL_LOG="$CASE_DIR/brazil.log" FM_FAKE_PANE_LOG="$CASE_DIR/pane.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_PATH" "$FAKEBIN_DIR" "$@"
}

test_scout_gets_its_own_brazil_workspace() {
  local id=brz-scout-a1 out status tip meta
  make_case scout "$id"
  tip=$(fm_brazil_advance_origin "$WS" PkgA advanced.txt)
  out=$(run_spawn "$id" "$PROJECT_DIR" --scout)
  status=$?
  expect_code 0 "$status" "a scout on a Brazil package should spawn"$'\n'"$out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "worktree=$WT_PATH" "$meta" "the task's worktree should be the package worktree of its own workspace"
  assert_grep "project_kind=brazil" "$meta" "the record should mark the Brazil workspace"
  assert_grep "workspace_shell=$SHELL_PATH" "$meta" "the record should name the workspace"
  assert_equals "$tip" "$(git -C "$WT_PATH" rev-parse HEAD)" "the worker should start at the freshly fetched origin tip"
  assert_equals "fm-$id" "$(git -C "$WT_PATH" symbolic-ref --short HEAD)" "the worktree should sit on the workspace branch"
  assert_equals origin/mainline "$(git -C "$WT_PATH" rev-parse --abbrev-ref '@{upstream}')" "the branch should track origin's default branch"
  assert_equals PkgA "$(cat "$SHELL_PATH/.fm-packages")" "the project's package should be declared"
  assert_grep "# Brazil workspace" "$HOME_DIR/data/$id/launch-brief.md" "the launch brief should carry the Brazil workspace section"
  assert_grep "bin/fm-worktree-add.sh <Package>" "$HOME_DIR/data/$id/launch-brief.md" "the launch brief should name the declare command"
  assert_no_grep "treehouse get" "$CASE_DIR/pane.log" "a Brazil spawn must not lease a Treehouse slot"
  assert_grep "cd -- '$WT_PATH'" "$CASE_DIR/pane.log" "the endpoint should be moved into the package worktree"
  pass "a fresh Brazil scout launches in its own workspace at a fresh origin tip with the record and brief that name it"
}

test_ship_records_the_brazil_workspace() {
  local id=brz-ship-a1 out status meta
  make_case ship "$id"
  out=$(run_spawn "$id" "$PROJECT_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "a ship on a Brazil package should spawn"$'\n'"$out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "worktree=$WT_PATH" "$meta" "the ship's worktree should be the package worktree"
  assert_grep "workspace_shell=$SHELL_PATH" "$meta" "the ship's record should name the workspace"
  assert_grep "mode=direct-PR" "$meta" "the ship keeps its delivery contract"
  pass "a fresh Brazil ship records its workspace alongside its delivery contract"
}

test_existing_workspace_refused_before_any_endpoint() {
  local id=brz-exists-a1 out status
  make_case exists "$id"
  mkdir -p "$SHELL_PATH"
  out=$(run_spawn "$id" "$PROJECT_DIR" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "an existing workspace path must refuse the spawn"
  assert_contains "$out" "Brazil workspace $SHELL_PATH already exists" "the refusal should name the workspace"
  assert_contains "$out" "brazil-worktree remove --name fm-$id" "the refusal should name the cleanup command"
  assert_absent "$HOME_DIR/state/$id.meta" "no record should be published"
  [ ! -s "$FAKEBIN_DIR/.spawn-window" ] || fail "no endpoint should be created for a refused workspace"
  [ -d "$SHELL_PATH" ] || fail "the existing workspace must be left alone"
  pass "a spawn refuses an existing workspace path before creating any endpoint"
}

test_missing_tool_refused() {
  local id=brz-notool-a1 out status
  make_case notool "$id"
  rm -f "$FAKEBIN_DIR/brazil-worktree"
  mkdir -p "$HOME_DIR/user-home"
  out=$(env PATH="$FAKEBIN_DIR:$(fm_test_base_path_sans "$PATH" brazil-worktree)" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_PATH" TMUX=fake,1,0 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT_DIR" --scout 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a Brazil spawn without brazil-worktree must be refused"
  assert_contains "$out" "toolbox install brazilworktreecli" "the refusal should name the install command"
  assert_absent "$HOME_DIR/state/$id.meta" "no record should be published"
  assert_absent "$SHELL_PATH" "no workspace should exist"
  pass "a Brazil spawn refuses without brazil-worktree rather than falling back to a shared workspace"
}

test_stale_base_refused_and_workspace_removed() {
  local id=brz-stale-a1 out status
  make_case stale "$id"
  git -C "$PROJECT_DIR" remote set-url origin "$CASE_DIR/gone.git"
  out=$(run_spawn "$id" "$PROJECT_DIR" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose package origin cannot be fetched must fail"
  assert_contains "$out" "refusing to start the worktree from a stale base" "the refusal should say why"
  assert_absent "$HOME_DIR/state/$id.meta" "no record should be published"
  assert_absent "$SHELL_PATH" "the half-built workspace should be removed"
  git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/fm-$id" && fail "no workspace branch should be left behind"
  assert_grep "remove --name fm-$id" "$CASE_DIR/brazil.log" "the cleanup should go through brazil-worktree"
  pass "a spawn that cannot fetch its package's origin refuses and removes the workspace it built"
}

# --- relaunch ---------------------------------------------------------------
#
# The stub models the pane just far enough for bin/fm-control.sh relaunch: the
# harness exit leaves a bare shell, and the launch command starts it again.
make_relaunch_stub() {  # <fakebin> <state-dir>
  local fb=$1
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        ". '"*"'") printf 'codex' > "$D/command" ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_test_fake_sleep_noop "$fb"
}

run_relaunch() {  # <id>
  env PATH="$CASE_DIR/relaunch-bin:$FAKEBIN_DIR:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_DIR="$CASE_DIR/pane" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$1" relaunch --note 'replacement continues the same task' 2>&1
}

# spawn_for_relaunch <name> <id>: a fresh Brazil ship, then a pane model that
# reports the task window and worktree so relaunch can adopt it.
spawn_for_relaunch() {
  local out
  make_case "$1" "$2"
  out=$(run_spawn "$2" "$PROJECT_DIR" --mode direct-PR --yolo off) || fail "fixture: the Brazil ship should spawn: $out"
  mkdir -p "$CASE_DIR/relaunch-bin" "$CASE_DIR/pane"
  make_relaunch_stub "$CASE_DIR/relaunch-bin"
  printf 'codex' > "$CASE_DIR/pane/command"
  printf '%s' "$WT_PATH" > "$CASE_DIR/pane/cwd"
  sed -n 's/^window=[^:]*://p' "$HOME_DIR/state/$2.meta" > "$CASE_DIR/pane/windows"
}

test_relaunch_reuses_an_intact_workspace() {
  local id=brz-relaunch-a1 out status head
  spawn_for_relaunch relaunch "$id"
  printf 'unsaved\n' > "$WT_PATH/work-in-progress.txt"
  head=$(git -C "$WT_PATH" rev-parse HEAD)
  out=$(run_relaunch "$id")
  status=$?
  expect_code 0 "$status" "relaunch should reuse an intact Brazil workspace"$'\n'"$out"
  assert_grep "worktree=$WT_PATH" "$HOME_DIR/state/$id.meta" "the relaunch should keep the package worktree"
  assert_equals 1 "$(grep -c '^workspace_shell=' "$HOME_DIR/state/$id.meta")" "the relaunch should carry the workspace forward once"
  assert_grep "project_kind=brazil" "$HOME_DIR/state/$id.meta" "the relaunch should keep the Brazil mark"
  [ -f "$WT_PATH/work-in-progress.txt" ] || fail "the relaunch must not touch uncommitted work"
  assert_equals "$head" "$(git -C "$WT_PATH" rev-parse HEAD)" "the relaunch must not move the worktree"
  assert_grep "# Brazil workspace" "$HOME_DIR/data/$id/launch-brief.md" "the replacement's brief should still carry the Brazil section"
  pass "a relaunch reuses an intact Brazil workspace and leaves its work alone"
}

test_relaunch_refuses_a_damaged_workspace() {
  local id=brz-relaunch-b1 out status
  spawn_for_relaunch relaunch-damaged "$id"
  rm "$SHELL_PATH/.fm-primary"
  out=$(run_relaunch "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch must refuse a damaged Brazil workspace"
  assert_contains "$out" "no readable .fm-primary" "the refusal should name what is broken"
  assert_contains "$out" "is not intact" "the refusal should say the workspace is not intact"
  pass "a relaunch refuses a Brazil workspace that lost its marker"
}

test_scout_gets_its_own_brazil_workspace
test_ship_records_the_brazil_workspace
test_existing_workspace_refused_before_any_endpoint
test_missing_tool_refused
test_stale_base_refused_and_workspace_removed
test_relaunch_reuses_an_intact_workspace
test_relaunch_refuses_a_damaged_workspace
