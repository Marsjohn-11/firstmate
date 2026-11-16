#!/usr/bin/env bash
# usage: <code-root> <label>
set -u
ROOT=$1; LABEL=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$PWD/bin/fm-lab-home.sh" create "$LAB" >/dev/null
touch "$LAB/config/supervision-host-off"
S="$LAB/state"; F="$S/task1.status"
run_drain() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_CONFIG_OVERRIDE="$LAB/config" "$ROOT/bin/fm-wake-drain.sh"; }
{
for i in $(seq 1 300); do printf 'note: history line %d\n' "$i"; done
printf 'needs-decision [key=release]: choose target\n'
} > "$F"
echo "=== [$LABEL] drain 1 (fresh history) ==="
run_drain | grep -c 'history line' | sed 's/^/history lines presented: /'
echo "--- persisted cursor identities before reboot ---"
grep -H '^ident=' "$S"/.task1.* 2>/dev/null
cut -f1-2 "$S/.status-presentation-cursor" 2>/dev/null
echo "real stat: $(stat -c 'dev=%d ino=%i' "$F")"
# simulate a macOS reboot renumbering the volume: shift device field (+3) in every persisted identity
dev=$(stat -c %d "$F"); nd=$((dev+3))
for c in "$S"/.task1.* "$S/.status-presentation-cursor"; do [ -f "$c" ] && sed -i "s/strong:$dev:/strong:$nd:/g; s/weak:$dev:/weak:$nd:/g" "$c"; done
echo "--- after simulated renumbering ($dev -> $nd) ---"
grep -H '^ident=' "$S"/.task1.* 2>/dev/null
printf 'note: first line after the reboot\n' >> "$F"
echo "=== [$LABEL] drain 2 (after renumbering) ==="
start=$EPOCHREALTIME; out=$(run_drain); end=$EPOCHREALTIME
echo "$out" | grep -c 'history line' | sed 's/^/replayed history lines: /'
echo "$out" | grep -F 'first line after the reboot' || echo "NEW LINE MISSING"
echo "$out" | grep -F 'choose target' | head -1 || true
awk -v s="$start" -v e="$end" 'BEGIN{printf "drain seconds: %.2f\n", e-s}'
echo "fold cursor: $(grep -h '^offset=' "$S/.task1.open-decisions-cursor" 2>/dev/null) file size=$(wc -c < "$F")"
# adversarial: replaced file (new inode) must still reset
cp "$F" "$LAB/repl"; mv "$LAB/repl" "$F"; printf 'note: after replacement\n' >> "$F"
echo "=== [$LABEL] drain 3 (file replaced, new inode $(stat -c %i "$F")) ==="
run_drain | grep -c 'history line' | sed 's/^/history lines re-presented: /'
rm -rf "$LAB"
