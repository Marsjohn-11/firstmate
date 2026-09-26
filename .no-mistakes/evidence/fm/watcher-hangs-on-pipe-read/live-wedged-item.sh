#!/usr/bin/env bash
# Adversarial live driver: one open pending reply whose endpoint observation
# hangs for 40s. The watcher runs with FM_WATCHER_BEAT_SECS=1. Progress beats
# must NOT refresh the beacon while that single item is stuck.
set -u
WT=/Users/marsjohn/.no-mistakes/worktrees/45849cd9dd00/01M3G0GP0R8Z6M7X62SP036YNC
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
state="$LAB/state"; fb="$LAB/fakebin"; mkdir -p "$fb"
cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane) echo x >> "$FM_TEST_CAPTURE_LOG"; sleep 40; printf 'idle pane\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
chmod +x "$fb/tmux"
(
  . "$WT/tests/lib.sh" >/dev/null 2>&1
  . "$WT/bin/fm-pending-reply-lib.sh"
  export FM_PENDING_REPLY_NOW=8000
  fm_write_secondmate_meta "$state/mate1.meta" "$LAB/mate1"
  corr=$(fm_pending_reply_create "$LAB" "$state" mate1 "stuck request")
  fm_pending_reply_mark_delivered "$state" "$corr"
)
cap="$LAB/captures.log"; : > "$cap"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  PATH="$fb:$PATH" FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WATCHER_BEAT_SECS=1 \
  FM_PENDING_REPLY_SEND_HOOK=true FM_TEST_CAPTURE_LOG="$cap" "$WT/bin/fm-watch.sh" > "$LAB/w.out" 2>&1 &
pid=$!
t=0; while [ ! -s "$cap" ] && [ "$t" -lt 120 ]; do sleep 0.5; t=$((t+1)); done
echo "stuck observation started"
max=0
for s in $(seq 1 30); do
  sleep 1
  age=$(( $(date +%s) - $(/usr/bin/stat -f %m "$state/.last-watcher-beat") ))
  [ "$age" -le "$max" ] || max=$age
  printf 't=%2ss beacon_age=%ss\n' "$s" "$age"
done
echo "== wedged item: beacon aged to ${max}s during a 30s stuck observation (beat interval 1s)"
kill "$pid"; pkill -f "$LAB"; wait 2>/dev/null; sleep 2; rm -rf "$LAB" 2>/dev/null || { sleep 3; rm -rf "$LAB"; }
