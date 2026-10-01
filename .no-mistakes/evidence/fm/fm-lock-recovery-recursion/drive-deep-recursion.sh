#!/usr/bin/env bash
# Deep stacked stale steal chain: original recursive revision (df4ae5d6^) vs fixed HEAD.
set -u
WT=$1; W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lockdrive3.XXXXXX")
mkdir -p "$W/old"; git -C "$WT" archive 'df4ae5d6^' bin | tar -x -C "$W/old"
mkdir -p "$W/fix"; cp -R "$WT/bin" "$W/fix/bin"
D=999999; while kill -0 $D 2>/dev/null; do D=$((D+1)); done
export FM_GATE_REFUSE_BYPASS=1
for rev in old fix; do
  st="$W/$rev-state"; mkdir -p "$st"; p="$st/.watch.lock"; mkdir "$p"; echo $D > "$p/pid"; n=0
  while [ $n -lt 40 ]; do p="$p.steal"; mkdir "$p" 2>/dev/null || break; echo $D > "$p/pid"; n=$((n+1)); done
  SECONDS=0
  FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$st" timeout 120 bash -c '. "$1"; fm_lock_try_acquire "$2"' _ "$W/$rev/bin/fm-wake-lib.sh" "$st/.watch.lock" >"$W/$rev.out" 2>&1; rc=$?
  echo "[$rev] stacked=$n rc=$rc elapsed=${SECONDS}s holder_pid=$(cat "$st/.watch.lock/pid" 2>/dev/null) (dead=$D) 'too long' lines=$(grep -c 'too long' "$W/$rev.out")"
  grep -m2 'too long' "$W/$rev.out" | cut -c1-140 | sed "s|$W|<tmp>|; s|^|[$rev]   |"
done
rm -rf "$W"
