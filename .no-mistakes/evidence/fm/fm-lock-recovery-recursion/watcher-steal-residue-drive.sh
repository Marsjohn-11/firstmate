#!/usr/bin/env bash
# Drive the REAL watcher (bin/fm-watch.sh) against a home whose watcher
# singleton lock is stale and whose steal-mutex residue has stacked up, the
# shape the recursion bug leaves behind. Usage:
#   watcher-steal-residue-drive.sh <bin-dir> <label> [levels] [budget-seconds]
set -u

BIN=$1
LABEL=$2
LEVELS=${3:-40}
BUDGET=${4:-45}

RUN="/tmp/fmlivetest/run-$LABEL"
rm -rf "$RUN"
STATE="$RUN/state"
FAKEBIN="$RUN/fakebin"
mkdir -p "$STATE" "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/tmux"

dead=999999
while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done

lock="$STATE/.watch.lock"
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
printf 'seeded: stale .watch.lock (dead pid %s) + %s stacked stale steal mutexes\n' "$dead" "$made"
printf 'longest residue component: %s bytes\n' "${#path}"

start=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_LOCK_STALE_AFTER=0 \
  FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$BIN/fm-watch.sh" > "$RUN/watch.out" 2>&1 &
wpid=$!

took=
while :; do
  now=$(date +%s)
  elapsed=$((now - start))
  if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$wpid" ]; then
    took=$elapsed
    break
  fi
  if [ "$elapsed" -ge "$BUDGET" ]; then
    break
  fi
  sleep 0.2
done

deepest=$(find "$STATE" -maxdepth 1 -name '.watch.lock.steal*' 2>/dev/null \
  | awk '{n=gsub(/\.steal/,"",$0); if (n>m) m=n} END {print m+0}')
cpu=$(ps -o time= -p "$wpid" 2>/dev/null | tr -d ' ' || true)

if [ -n "$took" ]; then
  printf 'RESULT: watcher took the singleton lock in %ss (pid %s)\n' "$took" "$wpid"
else
  printf 'RESULT: watcher NEVER took the singleton lock within %ss (holder pid recorded: %s)\n' \
    "$BUDGET" "$(cat "$lock/pid" 2>/dev/null || echo none)"
fi
printf 'watcher process cpu time after the attempt: %s\n' "${cpu:-gone}"
printf 'deepest .steal residue left under state/: depth %s\n' "$deepest"
printf 'nested mutex .watch.lock.steal.steal present: %s\n' \
  "$([ -e "$STATE/.watch.lock.steal.steal" ] && echo yes || echo no)"
printf 'watcher stderr/stdout (first 12 lines):\n'
sed -n 1,12p "$RUN/watch.out" | sed 's/^/  | /'
printf 'basename ENAMETOOLONG in watcher output: %s\n' \
  "$(grep -c 'too long' "$RUN/watch.out" 2>/dev/null || echo 0)"

kill -TERM "$wpid" 2>/dev/null || true
sleep 1
kill -9 "$wpid" 2>/dev/null || true
wait "$wpid" 2>/dev/null || true
[ -n "$took" ]
