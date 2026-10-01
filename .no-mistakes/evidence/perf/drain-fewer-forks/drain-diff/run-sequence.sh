#!/usr/bin/env bash
# usage: run.sh <bin-root> <home> <outdir>   ; drives a drain sequence
set -u
R=$1 H=$2 O=$3; mkdir -p "$O"
drain() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$H" "$R/bin/fm-wake-drain.sh" > "$O/$1.out" 2>"$O/$1.err"; echo "rc=$?" >> "$O/$1.out"; }
S=$H/state
drain d1
drain d2
printf 'needs-decision [key=late]: new question on task3\n' >> $S/task3.status
printf 'resolved [key=k5]: answered k5\n' >> $S/task5.status
printf 'done: finished task7\n' >> $S/task7.status
drain d3
# rotation: replace task10 with a new inode carrying a fresh decision
rm $S/task10.status; printf 'needs-decision [key=rot]: after rotation\n' > $S/task10.status
drain d4
# truncation in place (same inode, smaller size)
: > $S/task15.status; printf 'blocked [key=tr]: truncated then reopened\n' >> $S/task15.status
drain d5
# a file vanishes between drains
rm $S/task20.status
drain d6
drain d7
