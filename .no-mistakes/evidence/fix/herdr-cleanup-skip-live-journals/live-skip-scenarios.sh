#!/usr/bin/env bash
# Real restored-shell E2E for home-local session-start Herdr projection cleanup.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT=${ROOT:?set ROOT to the worktree}
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

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-session-start-stale-projection-cleanup-r1)
CALL_LOG="$TMP_ROOT/calls.log"; : > "$CALL_LOG"
export CALL_LOG HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
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
printf '%s\n' "$*" >> "$CALL_LOG"
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
run_cleanup() {
  : > "$CALL_LOG"
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" || fail 'cleanup command failed'
  echo "  herdr calls made by cleanup: $(wc -l < "$CALL_LOG" | tr -d ' ')"; sed 's/^/    > herdr /' "$CALL_LOG"
}
write_journal() { printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$1" "$2" > "$HOME_DIR/state/$1.herdr-presentation"; }

lab workspace create --cwd "$ROOT" --label captain-anchor --focus >/dev/null || fail 'anchor'
TOKEN=AbCdEfGhIjKlMnOpQrStUv; ID=live-task
CAND=$(lab workspace create --cwd "$ROOT" --label "└ $ID · p:$TOKEN" --no-focus) || fail 'candidate'
WS=$(printf '%s' "$CAND" | jq -r '.result.workspace.workspace_id'); PANE=$(printf '%s' "$CAND" | jq -r '.result.root_pane.pane_id')
write_journal "$ID" "$TOKEN"
: > "$HOME_DIR/state/$ID.meta"
sleep 2
echo "fixture: lab=$HERDR_LAB_SESSION workspace=$WS pane=$PANE journal=$ID.herdr-presentation meta=$ID.meta"

echo "== S1: only journal's task has live .meta"
run_cleanup
[ ! -s "$CALL_LOG" ] || fail 'S1 cleanup queried herdr although every journal task has .meta'
lab pane get "$PANE" >/dev/null 2>&1 || fail 'S1 pane gone'
[ -f "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'S1 journal gone'
pass 'S1 live .meta: zero herdr calls, pane and journal preserved'

echo "== S2: dangling-symlink .meta still counts as present"
rm "$HOME_DIR/state/$ID.meta"; ln -s "$TMP_ROOT/nowhere" "$HOME_DIR/state/$ID.meta"
run_cleanup
[ ! -s "$CALL_LOG" ] || fail 'S2 queried herdr'
lab pane get "$PANE" >/dev/null 2>&1 || fail 'S2 pane gone'
rm "$HOME_DIR/state/$ID.meta"; : > "$HOME_DIR/state/$ID.meta"
pass 'S2 dangling symlink .meta: zero herdr calls, pane preserved'

echo "== S3: a second journal lacks .meta -> discovery runs, live task preserved"
write_journal orphan BcDeFgHiJkLmNoPqRsTuVw
run_cleanup
grep -q '^workspace list' "$CALL_LOG" || fail 'S3 skipped discovery'
lab pane get "$PANE" >/dev/null 2>&1 || fail 'S3 closed live-task pane'
[ -f "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'S3 retired live-task journal'
rm "$HOME_DIR/state/orphan.herdr-presentation"
pass 'S3 one meta-less journal: discovery runs, live task pane and journal preserved'

echo "== S4: symlinked journal without meta is ignored for the gate"
ln -s "$TMP_ROOT/nowhere" "$HOME_DIR/state/linked.herdr-presentation"
run_cleanup
[ ! -s "$CALL_LOG" ] || fail 'S4 queried herdr because of a symlinked journal'
rm "$HOME_DIR/state/linked.herdr-presentation"
pass 'S4 symlinked journal does not trigger discovery'

echo "== S5: task .meta removed -> stale restored shell is retired"
rm "$HOME_DIR/state/$ID.meta"
for i in $(seq 50); do run_cleanup >/dev/null; lab pane get "$PANE" >/dev/null 2>&1 || break; sleep 0.2; done
grep -q '^workspace list' "$CALL_LOG" || true
lab pane get "$PANE" >/dev/null 2>&1 && fail 'S5 stale pane survived'
[ ! -e "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'S5 journal survived'
pass 'S5 meta-less journal: cleanup closes exact stale pane and retires journal'
