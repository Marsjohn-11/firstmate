#!/usr/bin/env bash
# drive-reemit.sh <checkout>: a full start publishes; a --reemit does not.
set -u
CO=$1
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX); "$CO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
r() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE FM_HOME="$LAB" "$CO/bin/fm-session-start.sh" "$@"; }
r > "$LAB.first" 2>&1; rc=$?; sleep 6
echo "full start: exit=$rc ledger=$([ -e "$LAB/state/home-summary.json" ] && echo present || echo absent)"
rm -f "$LAB/state/home-summary.json"; echo "ledger removed; running --reemit"
r --reemit > "$LAB.reemit" 2>&1; rc=$?
echo "reemit: exit=$rc lines=$(wc -l <"$LAB.reemit") header=$(grep -m1 'SESSION START' "$LAB.reemit")"
sleep 8; echo "ledger after reemit + 8s: $([ -e "$LAB/state/home-summary.json" ] && echo present || echo absent)"
rm -rf "$LAB" "$LAB.first" "$LAB.reemit"
