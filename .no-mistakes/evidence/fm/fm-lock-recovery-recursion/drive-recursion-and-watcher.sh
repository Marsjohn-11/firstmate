#!/usr/bin/env bash
# Live driver: original recursion (df4ae5d6^), base wedge (549e07f3), fixed (HEAD); then real fm-watch.sh.
set -u
WT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lockdrive2.XXXXXX")
for r in old:df4ae5d6^ base:549e07f37fd73aa01d74cd126b1111c99175abed; do
  mkdir -p "$W/${r%%:*}"; git -C "$WT" archive "${r#*:}" bin | tar -x -C "$W/${r%%:*}"
done
mkdir -p "$W/fix"; cp -R "$WT/bin" "$W/fix/bin"   # copy so gate-refuse sees a non-gate checkout
D=999999; while kill -0 $D 2>/dev/null; do D=$((D+1)); done
stack() { local p=$1 i=0; mkdir -p "$p"; echo $D > "$p/pid"; while [ $i -lt $2 ]; do p="$p.steal"; mkdir "$p" 2>/dev/null || break; echo $D > "$p/pid"; i=$((i+1)); done; echo $i; }
export FM_GATE_REFUSE_BYPASS=1

echo "=== R1: one stale lock + one stale steal mutex, fm_lock_acquire_wait (20s cap) ==="
for rev in old base fix; do
  st="$W/r1-$rev"; mkdir -p "$st"; stack "$st/.watch.lock" 1 >/dev/null
  SECONDS=0
  FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$st" timeout 20 bash -c '. "$1"; fm_lock_acquire_wait "$2"' _ "$W/$rev/bin/fm-wake-lib.sh" "$st/.watch.lock" >"$W/r1-$rev.out" 2>&1; rc=$?
  deep=$(ls -a "$st" | awk '{n=gsub(/\.steal/,"",$0); if(n>m)m=n} END{print m+0}')
  echo "[$rev] rc=$rc elapsed=${SECONDS}s holder_pid=$(cat "$st/.watch.lock/pid" 2>/dev/null) (dead=$D) deepest_steal_path_created=$deep 'File name too long' lines=$(grep -c 'too long' "$W/r1-$rev.out")"
  grep -m1 'too long' "$W/r1-$rev.out" | cut -c1-160 | sed "s|^|[$rev]   first error: |"
done

echo "=== R2: real fm-watch.sh in a marked lab home, stale .watch.lock + stale .watch.lock.steal ==="
mkdir -p "$W/fakebin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/tmux"; chmod +x "$W/fakebin/tmux"
for rev in base fix; do
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
  st="$LAB/state"; stack "$st/.watch.lock" 1 >/dev/null
  env -u TMUX -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$W/fakebin:$PATH" FM_HOME="$LAB" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$W/$rev/bin/fm-watch.sh" >"$W/r2-$rev.out" 2>&1 &
  wp=$!; i=0; got=
  while [ $i -lt 100 ]; do got=$(cat "$st/.watch.lock/pid" 2>/dev/null); [ -n "$got" ] && [ "$got" != "$D" ] && break; sleep 0.1; i=$((i+1)); done
  alive=$(kill -0 $wp 2>/dev/null && echo yes || echo no)
  echo "[$rev] watcher_alive_after_${i}x100ms=$alive .watch.lock_pid=$got watcher_pid=$wp acquired=$([ "$got" = "$wp" ] && echo yes || echo no)"
  tail -2 "$W/r2-$rev.out" | cut -c1-160 | sed "s|^|[$rev]   out: |"
  kill $wp 2>/dev/null; wait $wp 2>/dev/null; rm -rf "$LAB"
done
rm -rf "$W"
