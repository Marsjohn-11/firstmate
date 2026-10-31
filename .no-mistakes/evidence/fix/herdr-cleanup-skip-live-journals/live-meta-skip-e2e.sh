#!/usr/bin/env bash
# Real restored-shell E2E for home-local session-start Herdr projection cleanup.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT="/Users/marsjohn/.no-mistakes/worktrees/45849cd9dd00/01M68BP86ESX8FDB4S4FJQCJDM"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-session-cleanup-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' herdr > "$HOME_DIR/config/backend"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name meta-skip)
CLI_LOG="$TMP_ROOT/cli.log"
export CLI_LOG HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$CLI_LOG"
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
production_process_proof() {
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_herdr_pane_idle_shell_pid "$2" "$3" >/dev/null' \
      _ "$ROOT/bin/fm-herdr-session-cleanup.sh" "$HERDR_LAB_SESSION" "$PANE"
}
focus_snapshot() {
  local list workspace tab tabs
  list=$(lab workspace list) || return 1
  workspace=$(printf '%s' "$list" | jq -er '[.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].workspace_id') || return 1
  tab=$(printf '%s' "$list" | jq -er --arg workspace "$workspace" '[.result.workspaces[] | select(.workspace_id == $workspace)] | select(length == 1) | .[0].active_tab_id') || return 1
  tabs=$(lab tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '([.result.tabs[] | select(.focused == true)] | length) == 1 and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)' >/dev/null || return 1
  printf '%s\t%s' "$workspace" "$tab"
}

ANCHOR=$(lab workspace create --cwd "$ROOT" --label captain-anchor --focus) || fail 'could not create focus anchor'
ANCHOR_TAB=$(printf '%s' "$ANCHOR" | jq -r '.result.tab.tab_id')
TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=restored-idle-shell
TITLE="└ $ID · p:$TOKEN"
CANDIDATE=$(lab workspace create --cwd "$ROOT" --label "$TITLE" --no-focus) || fail 'could not create projected child fixture'
WS=$(printf '%s' "$CANDIDATE" | jq -r '.result.workspace.workspace_id')
PANE=$(printf '%s' "$CANDIDATE" | jq -r '.result.root_pane.pane_id')
{
  printf 'version=1\n'
  printf 'task_id=%s\n' "$ID"
  printf 'projection_id=%s\n' "$TOKEN"
} > "$HOME_DIR/state/$ID.herdr-presentation"

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop named lab for restored-shell reproduction'
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not restore named lab layout'
lab tab focus "$ANCHOR_TAB" >/dev/null || fail 'could not restore the anchor focus after lab restart'
BEFORE_FOCUS=$(focus_snapshot) || fail 'could not capture exact pre-cleanup focus'
[ "$BEFORE_FOCUS" = "$(printf '%s\t%s' "$(printf '%s' "$ANCHOR" | jq -r '.result.workspace.workspace_id')" "$ANCHOR_TAB")" ] \
  || fail 'anchor focus does not match the exact intended workspace and tab'

WORKSPACES=$(lab workspace list) || fail 'could not inspect restored workspaces'
TABS=$(lab tab list --workspace "$WS") || fail 'could not inspect restored tabs'
PANES=$(lab pane list --workspace "$WS") || fail 'could not inspect restored panes'
[ "$(printf '%s' "$WORKSPACES" | jq --arg title "$TITLE" '[.result.workspaces[] | select(.label == $title)] | length')" = 1 ] \
  || fail 'restored projected title is not unique'
[ "$(printf '%s' "$TABS" | jq '.result.tabs | length')" = 1 ] || fail 'restored child is not one tab'
[ "$(printf '%s' "$PANES" | jq '.result.panes | length')" = 1 ] || fail 'restored child is not one pane'
if lab agent get "$PANE" >/dev/null 2>&1; then
  fail 'restored child unexpectedly retained a registered agent'
fi
attempt=0
while [ "$attempt" -lt 50 ]; do
  if production_process_proof; then
    break
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done
[ "$attempt" -lt 50 ] || fail 'restored child did not converge to the exact childless idle-shell process-group shape'
pass 'real named lab reproduced the exact restored one-tab one-pane childless no-agent shell shape'


run_cleanup() {
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh"
}
# Scenario 1: the journal's task still has .meta -> no Herdr call at all, workspace and journal survive.
: > "$HOME_DIR/state/$ID.meta"
: > "$CLI_LOG"
run_cleanup || fail 'cleanup failed with live metadata'
echo "--- herdr calls made by cleanup with .meta present: $(wc -l < "$CLI_LOG" | tr -d ' ')"; cat "$CLI_LOG"
[ ! -s "$CLI_LOG" ] || fail 'cleanup queried Herdr although the only journal task has metadata'
lab workspace get "$WS" >/dev/null 2>&1 || fail 'projected workspace was removed despite live metadata'
lab pane get "$PANE" >/dev/null 2>&1 || fail 'projected pane was closed despite live metadata'
[ -f "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'journal retired despite live metadata'
pass 'live: journal with task metadata skips all Herdr discovery and leaves the projection intact'

# Scenario 2: a second journal without metadata (no matching workspace) -> discovery runs, but the meta-backed projection survives.
printf 'version=1\ntask_id=other\nprojection_id=BcDeFgHiJkLmNoPqRsTuVw\n' > "$HOME_DIR/state/other.herdr-presentation"
: > "$CLI_LOG"
run_cleanup || fail 'cleanup failed with mixed journals'
echo "--- herdr calls with one metadata-less journal:"; cat "$CLI_LOG"
grep -q '^workspace list' "$CLI_LOG" || fail 'discovery skipped although one journal lacks metadata'
lab pane get "$PANE" >/dev/null 2>&1 || fail 'meta-backed pane closed during mixed run'
[ -f "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'meta-backed journal retired during mixed run'
pass 'live: one metadata-less journal re-enables discovery without touching the meta-backed projection'

# Scenario 3 (control): remove .meta -> the same restored projection is cleaned up.
rm -f "$HOME_DIR/state/$ID.meta" "$HOME_DIR/state/other.herdr-presentation"
: > "$CLI_LOG"
run_cleanup || fail 'cleanup failed after metadata removal'
lab pane get "$PANE" >/dev/null 2>&1 && fail 'stale pane survived once metadata was gone'
[ ! -e "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'journal survived confirmed closure'
pass 'live control: once task metadata is gone the same projection is closed and its journal retired'
