#!/usr/bin/env bash
# Drive a real captain steer (bin/fm-send.sh) at a task whose steering inbox
# carries a stale sequence lock plus stacked stale steal-mutex residue - the
# state the recursion bug leaves behind. The durable record IS the delivery, so
# the observable result is the record fm-send writes.
#
# Usage: steer-over-steal-residue-drive.sh <bin-dir> <label> [levels] [budget]
set -u

BIN=$1
LABEL=$2
LEVELS=${3:-40}
BUDGET=${4:-60}

RUN="/tmp/fmlivetest/steer-$LABEL"
rm -rf "$RUN"
HOME_DIR="$RUN/home"
STATE="$HOME_DIR/state"
FAKEBIN="$RUN/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$HOME_DIR/wt" "$HOME_DIR/p"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

cat > "$STATE/build.meta" <<EOF
window=sess:fm-build
worktree=$HOME_DIR/wt
project=$HOME_DIR/p
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF

inbox="$STATE/build.inbox"
mkdir -p "$inbox/handled"
lock="$inbox/.seq.lock"
dead=999999
while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
mkdir "$lock"
printf '%s\n' "$dead" > "$lock/pid"
path="$lock"
made=0
while [ "$made" -lt "$LEVELS" ]; do
  path="$path.steal"
  mkdir "$path" 2>/dev/null || break
  printf '%s\n' "$dead" > "$path/pid" 2>/dev/null || break
  made=$((made + 1))
done

printf 'label=%s bin=%s\n' "$LABEL" "$BIN"
printf 'seeded: stale %s (dead pid %s) + %s stacked stale steal mutexes\n' \
  ".seq.lock" "$dead" "$made"

start=$(date +%s)
env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
  FM_SEND_LOG="$RUN/send.log" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  FM_LOCK_STALE_AFTER=0 FM_TASK_INBOX_LOCK_WAIT_SECS=30 \
  FM_GATE_REFUSE_BYPASS=1 \
  "$BIN/fm-send.sh" build "captain steer over stacked residue" \
  > "$RUN/send.out" 2>&1 &
sendpid=$!
while kill -0 "$sendpid" 2>/dev/null && [ $(( $(date +%s) - start )) -lt "$BUDGET" ]; do
  sleep 0.2
done
elapsed=$(( $(date +%s) - start ))
if kill -0 "$sendpid" 2>/dev/null; then
  printf 'RESULT: fm-send did NOT finish within %ss (still running)\n' "$BUDGET"
  kill -9 "$sendpid" 2>/dev/null || true
  rc=timeout
else
  wait "$sendpid"; rc=$?
  printf 'RESULT: fm-send exited %s after %ss\n' "$rc" "$elapsed"
fi

printf 'records written under %s:\n' "build.inbox"
find "$inbox" -maxdepth 1 -name '*.msg' | sed 's/^/  | /'
for rec in "$inbox"/*.msg; do
  [ -e "$rec" ] || continue
  printf 'record %s:\n' "${rec##*/}"
  sed 's/^/  | /' "$rec"
done
printf 'doorbell line typed into the pane: %s\n' "$(cat "$RUN/send.log" 2>/dev/null || echo none)"
printf 'fm-send output (first 6 lines):\n'
sed -n 1,6p "$RUN/send.out" | cut -c1-160 | sed 's/^/  | /'
printf 'basename ENAMETOOLONG lines in fm-send output: %s\n' \
  "$(grep -c 'too long' "$RUN/send.out" 2>/dev/null || echo 0)"

[ "$rc" = 0 ] && grep -rqF 'captain steer over stacked residue' "$inbox" \
  && printf 'VERDICT: steer delivered durably\n' \
  || printf 'VERDICT: steer NOT delivered\n'
[ "$rc" = 0 ]
