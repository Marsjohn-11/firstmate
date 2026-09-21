#!/usr/bin/env bash
# Drive the real fm-lock.sh CLI over a home whose depth-1 recovery mutex was left
# by a crashed stealer whose pid the kernel later handed to an unrelated process.
# usage: fm-recycled-lab.sh <tree> <mode: recycled|liveholder|primary> <timeout>
set -u
TREE=$1; MODE=$2; TMO=$3
LIB="$TREE/bin/fm-wake-lib.sh"
LAB=$(mktemp -d "/tmp/fm-recycled-lab.${MODE}.XXXXXX") || exit 1
STATE="$LAB/state"; mkdir -p "$STATE"
LOCK="$STATE/.lock.acquire"
DEAD=$(bash -c 'echo $$')

# An unrelated, innocent process that now owns the recycled pid.
sleep 300 & SQUAT=$!
echo "lab=$LAB mode=$MODE unrelated_live_pid=$SQUAT"

if [ "$MODE" = primary ]; then
  # The PRIMARY lock itself was left by a crashed holder whose pid got recycled.
  bash -c '. "$1"; fm_lock_try_create "$2"' _ "$LIB" "$LOCK" || { echo "seed failed"; exit 1; }
  printf '%s\n' "$SQUAT" > "$LOCK/pid"
  echo "seeded: primary lock records recycled pid $SQUAT, identity=$(head -c 40 "$LOCK/pid-identity" 2>/dev/null)..."
else
  mkdir "$LOCK"; printf '%s\n' "$DEAD" > "$LOCK/pid"
  bash -c '. "$1"; fm_lock_try_create "$2.steal"' _ "$LIB" "$LOCK" || { echo "seed failed"; exit 1; }
  [ -s "$LOCK.steal/pid-identity" ] || { echo "seed: no identity recorded"; exit 1; }
  printf '%s\n' "$SQUAT" > "$LOCK.steal/pid"
  if [ "$MODE" = liveholder ]; then
    # Control: the mutex genuinely belongs to that live process.
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$SQUAT" > "$LOCK.steal/pid-identity"
    echo "seeded: recovery mutex held by LIVE pid $SQUAT whose identity matches"
  else
    echo "seeded: recovery mutex records RECYCLED pid $SQUAT (identity is the crashed stealer's)"
  fi
fi

start=$(date +%s)
out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$STATE" timeout "$TMO" bash "$TREE/bin/fm-lock.sh" 2>&1)
rc=$?; end=$(date +%s)
echo "--- fm-lock.sh output ---"; printf '%s\n' "$out" | head -4
echo "exit=$rc elapsed_s=$((end-start))"
[ "$rc" -eq 124 ] && echo "verdict=CLI_BLOCKED (no claim taken)"
[ "$rc" -eq 0 ] && echo "verdict=CLAIM_TAKEN session_lock_line1=$(sed -n 1p "$STATE/.lock" 2>/dev/null)"
if [ "$MODE" = primary ]; then
  [ -e "$LOCK" ] && echo "primary_lock_still_present=yes" || echo "primary_lock_still_present=no"
else
  [ -e "$LOCK.steal" ] && echo "recovery_mutex_still_present=yes" || echo "recovery_mutex_still_present=no"
fi
if kill -0 "$SQUAT" 2>/dev/null; then echo "unrelated_process_unharmed=yes"; else echo "unrelated_process_unharmed=NO"; fi
kill -9 "$SQUAT" 2>/dev/null || true; wait "$SQUAT" 2>/dev/null || true
echo "lab_dir=$LAB"
