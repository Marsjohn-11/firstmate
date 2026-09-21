#!/usr/bin/env bash
# Adversarial drives against the REAL watcher (bin/fm-watch.sh) for the three
# verdicts the fix must keep apart on a home whose watcher lock is stale:
#
#   live-holder  a steal mutex whose live holder still matches its recorded
#                identity must NOT be stolen, so no second watcher appears.
#   recycled     a steal mutex whose recorded holder is gone and whose pid the
#                kernel handed to an unrelated process must be reclaimed, and
#                that unrelated process must be left running.
#   primary      a PRIMARY lock whose pid was recycled stays treated as live
#                (the documented limitation), so the watcher must not claim it.
#
# Usage: watcher-mutex-exclusion-drive.sh <bin-dir> <case> [budget-seconds]
set -u

BIN=$1
CASE=$2
BUDGET=${3:-20}
LIB="$BIN/fm-wake-lib.sh"

RUN="/tmp/fmlivetest/excl-$CASE"
rm -rf "$RUN"
STATE="$RUN/state"
FAKEBIN="$RUN/fakebin"
mkdir -p "$STATE" "$FAKEBIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"

dead=999999
while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done

lock="$STATE/.watch.lock"
steal="$lock.steal"

# An unrelated live process standing in for the recycled pid.
sleep 120 &
squatter=$!

seed_real_lock() {  # <path> - a genuine lock with owner dir, pid and identity
  bash -c '. "$1"; fm_lock_try_create "$2"' _ "$LIB" "$1" >/dev/null \
    || { echo "FIXTURE FAILED: could not create $1"; exit 3; }
}

case "$CASE" in
  live-holder)
    mkdir "$lock"; printf '%s\n' "$dead" > "$lock/pid"
    seed_real_lock "$steal"
    printf '%s\n' "$squatter" > "$steal/pid"
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$squatter" > "$steal/pid-identity"
    expect=refuse
    ;;
  recycled)
    mkdir "$lock"; printf '%s\n' "$dead" > "$lock/pid"
    seed_real_lock "$steal"
    # Keep the CRASHED holder's identity recorded, point the pid at the live
    # unrelated process: only the identity test tells these apart.
    printf '%s\n' "$squatter" > "$steal/pid"
    expect=claim
    ;;
  primary)
    seed_real_lock "$lock"
    printf '%s\n' "$squatter" > "$lock/pid"
    expect=refuse
    ;;
  *) echo "unknown case $CASE"; kill -9 "$squatter" 2>/dev/null; exit 2 ;;
esac

printf 'case=%s bin=%s expect=%s\n' "$CASE" "$BIN" "$expect"
printf 'seeded: .watch.lock pid=%s  steal mutex pid=%s  unrelated live pid=%s\n' \
  "$(cat "$lock/pid" 2>/dev/null || echo none)" \
  "$(cat "$steal/pid" 2>/dev/null || echo absent)" "$squatter"

PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_LOCK_STALE_AFTER=0 \
  FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$BIN/fm-watch.sh" > "$RUN/watch.out" 2>&1 &
wpid=$!

claimed=no
start=$(date +%s)
while :; do
  elapsed=$(( $(date +%s) - start ))
  if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$wpid" ]; then claimed=yes; break; fi
  [ "$elapsed" -ge "$BUDGET" ] && break
  sleep 0.2
done

squatter_live=no
kill -0 "$squatter" 2>/dev/null && squatter_live=yes
printf 'RESULT: watcher claimed the singleton lock: %s (after %ss)\n' "$claimed" "$elapsed"
printf 'lock pid now: %s\n' "$(cat "$lock/pid" 2>/dev/null || echo none)"
printf 'steal mutex still present: %s\n' "$([ -e "$steal" ] && echo yes || echo no)"
printf 'unrelated live process still running: %s\n' "$squatter_live"

kill -TERM "$wpid" 2>/dev/null || true
sleep 1
kill -9 "$wpid" "$squatter" 2>/dev/null || true
wait "$wpid" "$squatter" 2>/dev/null || true

rc=0
case "$expect" in
  claim)  [ "$claimed" = yes ] || rc=1 ;;
  refuse) [ "$claimed" = no ] || rc=1 ;;
esac
[ "$squatter_live" = yes ] || rc=1
[ "$rc" -eq 0 ] && printf 'VERDICT: pass\n' || printf 'VERDICT: fail\n'
exit "$rc"
