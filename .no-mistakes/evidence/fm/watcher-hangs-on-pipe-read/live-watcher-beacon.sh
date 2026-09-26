#!/usr/bin/env bash
# Live driver: run the real bin/fm-watch.sh from <root> against a disposable lab
# home holding a large settled pending-reply history, sample the liveness beacon
# age every second, and try a second arm (the Stop-hook auto-arm path) mid-run.
# Usage: live-watcher-beacon.sh <label> <root> <records> <seconds> <arm-at>
set -u
label=$1 root=$2 records=$3 secs=$4 arm_at=$5
WT=/Users/marsjohn/.no-mistakes/worktrees/45849cd9dd00/01M3G0GP0R8Z6M7X62SP036YNC
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
state="$LAB/state"

# Seed history with the root's own library, exactly as the watcher reads it.
(
  . "$root/bin/fm-pending-reply-lib.sh"
  export FM_PENDING_REPLY_NOW=7000
  dir=$(fm_pending_reply_dir "$state")
  settled=$(fm_pending_reply_create "$LAB" "$state" hibit "settled request")
  fm_pending_reply_mark_delivered "$state" "$settled"
  printf 'done [corr=%s]: settled\n' "$settled" >> "$state/hibit.status"
  fm_pending_reply_try_resolve "$state" "$settled" || { echo "seed resolve failed"; exit 1; }
  template=$(fm_pending_reply_path "$state" "$settled")
  i=1
  while [ "$i" -lt "$records" ]; do
    id=$(printf '%016x' "$i")
    sed "s/^corr_id=.*/corr_id=$id/" "$template" > "$dir/$id"
    [ $((i % 2)) -ne 0 ] || printf 'escalated_epoch=6000\nescalation_closed_epoch=6500\n' >> "$dir/$id"
    i=$((i + 1))
  done
  rm -f "$state/hibit.status"
) || exit 1

# Hermetic tmux: never reach any real tmux server.
fb="$LAB/fakebin"; mkdir -p "$fb"
printf '#!/bin/sh\ncase "$1" in list-windows|list-panes|display-message) exit 0;; esac\nexit 1\n' > "$fb/tmux"
chmod +x "$fb/tmux"

run_watch() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    PATH="$fb:$PATH" FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_WATCHER_STALE_GRACE=15 FM_WATCHER_STALL_BOUND=99999 "$root/bin/fm-watch.sh" "$@"
}

echo "== $label: $(ls "$state/pending-replies" 2>/dev/null | wc -l | tr -d ' ') records, grace 15s, load $(sysctl -n vm.loadavg)"
run_watch > "$LAB/watch1.out" 2>&1 &
pid=$!
beat="$state/.last-watcher-beat"
max=0 t=0 arm_out='' arm_rc=''
while [ "$t" -lt "$secs" ]; do
  sleep 1; t=$((t + 1))
  kill -0 "$pid" 2>/dev/null || { echo "watcher exited early: $(tail -5 "$LAB/watch1.out")"; break; }
  if [ -e "$beat" ]; then
    age=$(( $(date +%s) - $(/usr/bin/stat -f %m "$beat") ))
    [ "$age" -le "$max" ] || max=$age
    printf 't=%3ss beacon_age=%ss\n' "$t" "$age"
  else
    printf 't=%3ss beacon missing\n' "$t"
  fi
  if [ "$t" = "$arm_at" ]; then
    arm_out=$(run_watch 2>&1); arm_rc=$?
    echo "   second arm at t=${t}s rc=$arm_rc: $arm_out"
  fi
done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
pkill -f "$LAB" 2>/dev/null
echo "== $label: max beacon age ${max}s over ${secs}s; second arm rc=$arm_rc"
sleep 2; rm -rf "$LAB" 2>/dev/null || { sleep 3; rm -rf "$LAB"; }
