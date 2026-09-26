#!/usr/bin/env bash
# Usage: lab-sweep-guard.sh <code-root> <label>
# Real fm-watch.sh on a disposable marked lab FM_HOME with 8 registered 3s checks
# (one sweep ~24s) against a 12s grace; polls real fm-guard.sh every 2s.
set -u
ROOT=$1; LABEL=$2; WT=/Users/marsjohn/.no-mistakes/worktrees/45849cd9dd00/01M3DWT44H0T7B1WSJZCW6TGK4
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
clean() { [ -n "${W:-}" ] && kill -TERM "$W" 2>/dev/null; wait "$W" 2>/dev/null; rm -rf "$LAB"; }
trap clean EXIT
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
S=$LAB/state
printf 'window=lab:w1\nbackend=tmux\nkind=crew\n' > "$S/crew.meta"
for i in 1 2 3 4 5 6 7 8; do
  printf '#!/usr/bin/env bash\ndate +%%s >> %s/checks.log\nsleep 3\nexit 0\n' "$LAB" > "$S/sweep$i.check.sh"
  chmod 700 "$S/sweep$i.check.sh"
  run "$ROOT/bin/fm-check-register.sh" "sweep$i" >/dev/null || { echo "register failed"; exit 1; }
done
( cd "$ROOT" && run FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
  FM_CHECK_TIMEOUT=30 FM_WATCHER_STALE_GRACE=12 bin/fm-watch.sh > "$LAB/watch.out" 2>&1 ) &
W=$!
echo "[$LABEL] code=$ROOT lab=$LAB grace=12s, 8 checks x 3s"
alarms=0; worst=0
for n in $(seq 1 25); do
  sleep 2
  now=$(date +%s); m=$(stat -f %m "$S/.last-watcher-beat" 2>/dev/null || echo "$now"); age=$((now-m))
  [ "$age" -gt "$worst" ] && worst=$age
  g=$(cd "$ROOT" && run FM_GUARD_GRACE=12 bin/fm-guard.sh 2>&1 | tr '\n' ' ' | cut -c1-160)
  case "$g" in *[Ss]upervision*|*STALE*|*stale*|*hung*|*HUNG*|*DOWN*) alarms=$((alarms+1));; esac
  printf 't+%02ds beacon_age=%2ss checks_run=%s guard=[%s]\n' $((n*2)) "$age" "$(wc -l < "$LAB/checks.log" 2>/dev/null | tr -d ' ')" "$g"
done
echo "[$LABEL] RESULT worst_beacon_age=${worst}s guard_alarm_samples=$alarms watcher_alive=$(kill -0 $W 2>/dev/null && echo yes || echo no)"
