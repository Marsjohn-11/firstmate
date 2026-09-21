#!/usr/bin/env bash
# Drive the real fm-lock.sh CLI over a home whose recovery mutexes piled up.
# usage: fm-lock-lab.sh <tree> <label> <levels> <timeout>
set -u
TREE=$1; LABEL=$2; LEVELS=$3; TMO=$4
LAB=$(mktemp -d "/tmp/fm-lock-lab.${LABEL}.XXXXXX") || exit 1
STATE="$LAB/state"
mkdir -p "$STATE"
DEAD=$(bash -c 'echo $$')
LOCK="$STATE/.lock.acquire"
mkdir "$LOCK"; printf '%s\n' "$DEAD" > "$LOCK/pid"
p="$LOCK"; n=0
while [ "$n" -lt "$LEVELS" ]; do
  p="$p.steal"
  mkdir "$p" 2>/dev/null || break
  printf '%s\n' "$DEAD" > "$p/pid" 2>/dev/null || break
  n=$((n+1))
done
echo "lab=$LAB tree=$TREE seeded_stale_steal_levels=$n dead_pid=$DEAD"
start=$(date +%s)
out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$STATE" timeout "$TMO" bash "$TREE/bin/fm-lock.sh" 2>&1)
rc=$?
end=$(date +%s)
echo "--- fm-lock.sh stdout/stderr (first 6 lines) ---"
printf '%s\n' "$out" | head -6
echo "--- outcome ---"
echo "exit=$rc elapsed_s=$((end-start))"
[ "$rc" -eq 124 ] && echo "verdict=TIMED_OUT_WEDGED (no claim, operator blocked)"
deepest=$(find "$STATE" -maxdepth 1 -name '.lock.acquire*' -print 2>/dev/null \
  | awk '{p=$0; n=gsub(/\.steal/,"",p); if (n>m) m=n} END {print m+0}')
echo "deepest_steal_depth_left_on_disk=$deepest"
echo "session_lock_line1=$(sed -n 1p "$STATE/.lock" 2>/dev/null || echo '<none>')"
echo "lab_dir=$LAB"
