#!/usr/bin/env bash
# usage: <code-root> <label>  - drive daemon + watcher overdue-marker reconcile across a renumbered device
set -u
ROOT=$1; LABEL=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$PWD/bin/fm-lab-home.sh" create "$LAB" >/dev/null
: > "$LAB/config/pause-ceiling"; S="$LAB/state"; T=overdue-dev; F="$S/$T.status"; M="$S/.paused-overdue-$T"
printf 'paused: waiting for dependency\nblocked [key=paused-overdue-%s]: overdue\n' "$T" > "$F"
read -r dev ino <<< "$(stat -c '%d %i' "$F")"; size=$(wc -c < "$F" | tr -d ' ')
for who in daemon watcher; do
  printf '%s %s:%s\n' "$((dev + 3))" "$ino" "$size" > "$M"
  if [ $who = daemon ]; then
    ( export FM_HOME="$LAB" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$LAB/config"; . "$ROOT/bin/fm-supervise-daemon.sh"; reconcile_overdue_pause "$S" "$T" ); rc=$?
  else
    FM_HOME="$LAB" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$LAB/config" bash -c '. "$1"; pause_overdue_reconcile "$2" "$3"' _ "$ROOT/bin/fm-watch.sh" "$T" "$F"; rc=$?
  fi
  echo "[$LABEL] $who, device renumbered $dev->$((dev+3)): rc=$rc marker=$([ -s "$M" ] && echo kept || echo REMOVED)"
  printf '%s %s:%s\n' "$dev" "$((ino + 1))" "$size" > "$M"
  if [ $who = daemon ]; then
    ( export FM_HOME="$LAB" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$LAB/config"; . "$ROOT/bin/fm-supervise-daemon.sh"; reconcile_overdue_pause "$S" "$T" ); rc=$?
  else
    FM_HOME="$LAB" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$LAB/config" bash -c '. "$1"; pause_overdue_reconcile "$2" "$3"' _ "$ROOT/bin/fm-watch.sh" "$T" "$F"; rc=$?
  fi
  echo "[$LABEL] $who, different inode (adversarial): rc=$rc marker=$([ -e "$M" ] && echo kept || echo removed)"
done
rm -rf "$LAB"
