#!/usr/bin/env bash
# usage: live-lab.sh <repo-root> <label>
# Real fm-watch.sh in a disposable lab home, ten registered 2s checks (~20s+ sweep),
# 12s grace; real fm-guard.sh sampled every 2s for ~70s.
set -u
R=$1; L=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
S="$LAB/state"; mkdir -p "$S"
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
for i in $(seq 1 10); do
  printf '#!/usr/bin/env bash\ndate +%%s >> %s/checks.log\nsleep 2\nexit 0\n' "$LAB" > "$S/sweep$i.check.sh"
  chmod 700 "$S/sweep$i.check.sh"
  run "$R/bin/fm-check-register.sh" "sweep$i" >/dev/null || echo "register $i failed"
done
run FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 FM_CHECK_TIMEOUT=30 \
  FM_WATCHER_STALE_GRACE=12 "$R/bin/fm-watch.sh" > "$LAB/watch.out" 2>&1 &
W=$!
echo "[$L] watcher pid $W, grace 12s"
alarms=0; worst=0
for n in $(seq 1 35); do
  sleep 2
  kill -0 $W 2>/dev/null || { echo "[$L] watcher exited: $(tail -3 $LAB/watch.out)"; break; }
  [ -e "$S/.last-watcher-beat" ] || continue
  age=$(( $(date +%s) - $(stat -f %m "$S/.last-watcher-beat") ))
  [ $age -gt $worst ] && worst=$age
  g=$(cd "$R" && run FM_GUARD_GRACE=12 FM_WATCHER_STALE_GRACE=12 "$R/bin/fm-guard.sh" 2>&1)
  if printf '%s' "$g" | grep -qiE 'supervision|watcher'; then
    alarms=$((alarms+1)); echo "[$L] t=$((n*2))s beacon=${age}s GUARD: $(printf '%s' "$g" | grep -iE 'supervision|watcher' | head -2 | tr '\n' ' ')"
  else
    echo "[$L] t=$((n*2))s beacon=${age}s guard silent"
  fi
done
kill -TERM $W 2>/dev/null; wait $W 2>/dev/null
sweeps=$(awk 'NR%10==0{c++} END{print c+0}' "$LAB/checks.log")
span=$(awk 'NR%10==1{s=$1} NR%10==0{d=$1-s; if(d>m)m=d} END{print m+0}' "$LAB/checks.log")
echo "[$L] SUMMARY complete_sweeps=$sweeps longest_sweep=${span}s worst_beacon_age=${worst}s grace=12s guard_alarms=$alarms"
"$R/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"
