#!/usr/bin/env bash
# Manual acceptance drive: a source that keeps failing across many reconcile
# cycles (failing episodes separated by brief recoveries), gate off vs on.
set -u
ROOT=$1; MODE=$2; T=$(mktemp -d /tmp/u2drive/run.XXXXXX)
export FM_PROCEVENT_CLAIM_ROOT=$T/claims LAVISH_AXI_STATE_DIR=$T/lavish; mkdir -p $T/lavish
H=$T/home; mkdir -p $H/state $H/config
[ "$MODE" = on ] && printf 'repeat-seconds=3600\nrecovered-wake=on\n' > $H/config/procevent-failure-wakes
printf '#!/usr/bin/env bash\nprintf "result\\n"\n' > $T/src.sh; chmod +x $T/src.sh
pe() { FM_HOME=$H "$ROOT/bin/fm-procevent.sh" "$@"; }
pe register lavish flaky -- $T/src.sh >/dev/null
cp $H/state/procevent/flaky.source $T/good; awk '/^argv:$/{print;exit}{print}' $T/good > $T/bad
cnt() { awk -F'\t' -v p="procevent:flaky:$1:" '$3=="check"&&index($4,p)==1' $H/state/.wake-queue 2>/dev/null | grep -c . ; }
release() { for _ in $(seq 1 300); do [ -e $T/claims/flaky.claim ] || return; sleep 0.1; done; }
fails=0
for ep in 1 2 3 4; do
  cat $T/bad > $H/state/procevent/flaky.source
  for c in 1 2 3; do FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=1 pe reconcile >/dev/null 2>&1; fails=$((fails+1)); done
  echo "[$MODE] episode $ep: failing launches so far=$fails  failed-wakes=$(cnt launch-failed) recovered-wakes=$(cnt launch-recovered)"
  if [ $ep -lt 4 ]; then cat $T/good > $H/state/procevent/flaky.source
    echo "  repair: $(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=30 pe reconcile 2>&1 | tail -1)"; release; fi
done
echo "--- fleet view (while failing) ---"; FM_HOME=$H "$ROOT/bin/fm-fleet-view.sh" 2>/dev/null | sed -n '/Quiet Process-Event/,/^$/p;/No process-event failures/p'
cat $T/good > $H/state/procevent/flaky.source
echo "final repair: $(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=30 pe reconcile 2>&1 | tail -1)"; release
echo "[$MODE] TOTAL: failing launches=$fails failed-wakes=$(cnt launch-failed) recovered-wakes=$(cnt launch-recovered)"
echo "--- wake queue payloads ---"; awk -F'\t' '$3=="check"{print $4" | "$5}' $H/state/.wake-queue 2>/dev/null
echo "--- watcher headline ---"; FM_HOME=$H bash -c '. "$1/bin/fm-watch.sh"; procevent_surface_queued' _ "$ROOT"
echo "--- fleet view (after recovery) ---"; FM_HOME=$H "$ROOT/bin/fm-fleet-view.sh" 2>/dev/null | sed -n '/Quiet Process-Event/,/^$/p;/No process-event failures/p'
[ -e $H/state/procevent/.failure-quiet.log ] && { echo "--- quiet log ---"; cat $H/state/procevent/.failure-quiet.log; }
pe retire flaky >/dev/null 2>&1; release; rm -rf $T
