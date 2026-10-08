#!/usr/bin/env bash
# drive-slow-summary.sh <firstmate-checkout> <label>: run the real session start
# against a fresh lab home whose home-summary validation stalls 20s.
set -u
CO=$1 LABEL=$2
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX); "$CO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SHIM=$(mktemp -d /tmp/fm-shim.XXXXXX); REALJQ=$(command -v jq)
cat > "$SHIM/jq" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in */.home-summary.json.*) sleep 20 ;; esac; done
exec "$REALJQ" "\$@"
SH
chmod +x "$SHIM/jq"
s=$(date +%s%N)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE \
  PATH="$SHIM:$PATH" FM_HOME="$LAB" "$CO/bin/fm-session-start.sh" > "$LAB.digest" 2>&1
rc=$?; ms=$(( ($(date +%s%N)-s)/1000000 ))
echo "[$LABEL] digest exit=$rc elapsed_ms=$ms lines=$(wc -l <"$LAB.digest")"
echo "[$LABEL] ledger present at digest return: $([ -e "$LAB/state/home-summary.json" ] && echo yes || echo no)"
echo "[$LABEL] refresh still running: $(pgrep -f "$CO/bin/fm-home-summary-refresh.sh" >/dev/null && echo yes || echo no)"
for i in $(seq 1 40); do [ -e "$LAB/state/home-summary.json" ] && break; sleep 1; done
echo "[$LABEL] ledger after wait: $(jq -c '{schema,home,generated}' "$LAB/state/home-summary.json" 2>&1)"
echo "[$LABEL] refresh log: $(cat "$LAB/state/.home-summary-refresh.log" 2>/dev/null || echo '(none)')"
rm -rf "$LAB" "$LAB.digest" "$SHIM"
