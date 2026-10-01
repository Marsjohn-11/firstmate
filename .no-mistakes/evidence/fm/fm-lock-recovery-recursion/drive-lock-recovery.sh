#!/usr/bin/env bash
# Live driver: base (549e07f3) vs fixed (HEAD) fm-wake-lib.sh lock recovery.
set -u
WT=$1; EV=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lockdrive.XXXXXX")
mkdir -p "$W/base"
git -C "$WT" archive 549e07f37fd73aa01d74cd126b1111c99175abed bin | tar -x -C "$W/base"
BASE="$W/base/bin/fm-wake-lib.sh"; FIX="$WT/bin/fm-wake-lib.sh"
dead() { local p=999999; while kill -0 $p 2>/dev/null; do p=$((p+1)); done; echo $p; }
D=$(dead)
stack() { # <lock> <levels>
  local p=$1 i=0; mkdir -p "$p"; echo $D > "$p/pid"
  while [ $i -lt $2 ]; do p="$p.steal"; mkdir "$p" 2>/dev/null || break; echo $D > "$p/pid"; i=$((i+1)); done; echo $i; }
maxdepth() { find "$(dirname "$1")" -maxdepth 1 -name "$(basename "$1")*" 2>/dev/null | awk '{n=gsub(/\.steal/,"",$0); if(n>m)m=n} END{print m+0}'; }
export FM_GATE_REFUSE_BYPASS=1

echo "=== S1: stacked stale steal chain (40 levels), single acquirer ==="
for rev in base fix; do
  lib=$BASE; [ $rev = fix ] && lib=$FIX
  st="$W/s1-$rev"; mkdir -p "$st"; n=$(stack "$st/.watch.lock" 40)
  SECONDS=0
  ( FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$st" timeout 90 bash -c '. "$1"; fm_lock_try_acquire "$2"' _ "$lib" "$st/.watch.lock" ) >"$W/s1-$rev.out" 2>&1; rc=$?
  echo "[$rev] stacked=$n rc=$rc elapsed=${SECONDS}s holder_pid=$(cat "$st/.watch.lock/pid" 2>/dev/null) remaining_steal_depth=$(maxdepth "$st/.watch.lock") errors=$(grep -c 'too long' "$W/s1-$rev.out")"
  grep -m2 -o '[a-z]*name: .*too long\|File name too long' "$W/s1-$rev.out" | head -2 | sed "s|^|[$rev]   |"
done

echo "=== S2: 8 concurrent recoverers on stale lock + stale steal chain (6 levels) ==="
for rev in base fix; do
  lib=$BASE; [ $rev = fix ] && lib=$FIX
  st="$W/s2-$rev"; mkdir -p "$st"; stack "$st/.watch.lock" 6 >/dev/null
  pids=""; SECONDS=0
  for k in 1 2 3 4 5 6 7 8; do
    ( FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$st" timeout 90 bash -c '. "$1"; if fm_lock_try_acquire "$2"; then echo WIN $$; sleep 2; fm_lock_release "$2"; else echo LOSE; fi' _ "$lib" "$st/.watch.lock" ) >"$W/s2-$rev.$k" 2>&1 &
    pids="$pids $!"
  done
  rcs=""; for p in $pids; do wait $p; rcs="$rcs $?"; done
  wins=$(cat "$W"/s2-$rev.* | grep -c '^WIN'); tl=$(cat "$W"/s2-$rev.* | grep -c 'too long')
  echo "[$rev] winners=$wins exit_codes=[$rcs ] elapsed=${SECONDS}s name_too_long_errors=$tl nested_left=$(maxdepth "$st/.watch.lock")"
done

echo "=== S3 (adversarial): live steal-mutex holder must not be reclaimed ==="
st="$W/s3"; mkdir -p "$st"; sleep 60 & LIVE=$!
mkdir "$st/.watch.lock" "$st/.watch.lock.steal"; echo $D > "$st/.watch.lock/pid"; echo $LIVE > "$st/.watch.lock.steal/pid"
FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$st" bash -c '. "$1"; fm_lock_try_acquire "$2"' _ "$FIX" "$st/.watch.lock" >/dev/null 2>&1; rc=$?
echo "[fix] rc=$rc (expect nonzero) steal_pid_still=$(cat "$st/.watch.lock.steal/pid") live=$LIVE primary_pid_still=$(cat "$st/.watch.lock/pid")"
kill $LIVE; wait $LIVE 2>/dev/null

echo "=== S4: steal mutex whose recorded pid was recycled onto a live process is reclaimed ==="
st="$W/s4"; mkdir -p "$st"; sleep 60 & LIVE=$!
mkdir "$st/.watch.lock" "$st/.watch.lock.steal"; echo $D > "$st/.watch.lock/pid"; echo $LIVE > "$st/.watch.lock.steal/pid"
echo "proc-starttime=1 cmdline-hex=deadbeef" > "$st/.watch.lock.steal/pid-identity"
FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$st" bash -c '. "$1"; fm_lock_try_acquire "$2"' _ "$FIX" "$st/.watch.lock" >/dev/null 2>&1; rc=$?
echo "[fix] rc=$rc (expect 0) new_holder_pid=$(cat "$st/.watch.lock/pid" 2>/dev/null) steal_left=$([ -e "$st/.watch.lock.steal" ] && echo yes || echo no) live_proc_untouched=$(kill -0 $LIVE 2>/dev/null && echo yes || echo no)"
kill $LIVE; wait $LIVE 2>/dev/null

echo "=== S5 (adversarial): PRIMARY lock with recycled pid stays treated as live ==="
st="$W/s5"; mkdir -p "$st"; sleep 60 & LIVE=$!
mkdir "$st/.watch.lock"; echo $LIVE > "$st/.watch.lock/pid"; echo "proc-starttime=1 cmdline-hex=deadbeef" > "$st/.watch.lock/pid-identity"
FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$st" bash -c '. "$1"; fm_lock_try_acquire "$2"; echo "rc=$? held_pid=$FM_LOCK_HELD_PID"' _ "$FIX" "$st/.watch.lock" 2>/dev/null
echo "[fix] primary_pid_still=$(cat "$st/.watch.lock/pid") (expect $LIVE)"
kill $LIVE; wait $LIVE 2>/dev/null

echo "=== S6: identity recorded on fresh acquisition ==="
st="$W/s6"; mkdir -p "$st"
FM_STATE_OVERRIDE="$st" bash -c '. "$1"; fm_lock_try_acquire "$2" && { echo "pid=$(cat "$2/pid") self=$$"; echo "identity=$(cut -c1-60 "$2/pid-identity")"; fm_lock_release "$2"; echo "released_exists=$([ -e "$2" ] && echo yes || echo no)"; }' _ "$FIX" "$st/.x.lock"
rm -rf "$W"
