#!/usr/bin/env bash
# Live driver (round 5): real bin/fm-home-summary-refresh.sh against a disposable home.
set -u
ROOT=$1; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-hs-lab.XXXXXX"); trap 'pkill -KILL -f "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
W="$ROOT/bin/fm-home-summary-refresh.sh"
H="$LAB/home"; FB="$LAB/fakebin"; SB="$LAB/stubborn"; RB="$LAB/rmhang"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects" "$FB" "$SB" "$RB"
printf '# home\n' > "$H/AGENTS.md"; printf 'lab\n' > "$H/.fm-secondmate-home"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
printf '#!/usr/bin/env bash\ncase "${1:-}" in display-message) printf "%%%%1\\n";; capture-pane) printf "p\\n> \\n";; esac\nexit 0\n' > "$FB/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
REAL_JQ=$(command -v jq); REAL_RM=$(command -v rm)
cat > "$SB/jq" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in */.home-summary.json.*) trap '' TERM; while :; do sleep 0.1; done;; esac; done
exec "$REAL_JQ" "$@"
SH
cat > "$RB/rm" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *.home-summary-error.*) trap '' TERM; sleep 60;; esac; done
exec "$REAL_RM" "$@"
SH
chmod +x "$FB"/* "$SB/jq" "$RB/rm"; export REAL_JQ REAL_RM
rec() { cat "$H/state/.home-summary-refresh.backoff" 2>/dev/null || echo none; }
gen() { cat "$H/state/.home-summary-refresh.generation" 2>/dev/null || echo none; }
left() { find "$H/state" -maxdepth 1 \( -name '.home-summary.json.*' -o -name '.home-summary-error.*' -o -name '*.tmp.*' \) | wc -l | tr -d ' '; }
run() { PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" "$W" "$@"; }
stall() { PATH="$SB:$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=${T:-3} "$W" --best-effort; }
echo "load: $(uptime | sed 's/.*load/load/')"
echo "== S1 success publishes and bumps generation"; run; echo "rc=$? ledger=$(test -s "$H/state/home-summary.json" && echo yes) generation=$(gen) record=$(rec)"
echo "== S2 killed worker: bounded, reaped, counted"
for i in 1 2 3; do s=$(date +%s); stall; rc=$?; echo "attempt $i rc=$rc elapsed=$(( $(date +%s)-s ))s leftovers=$(left) record=$(rec)"; done
run; echo "after success: record=$(rec) generation=$(gen)"
echo "== S3 same-second miss after a publish is still recorded"
ok=0; n=${SS:-4}
for r in $(seq 1 $n); do run; pub=$(stat -f %m "$H/state/home-summary.json"); s=$(date +%s); stall; got=$(rec)
  [ "$got" = 1 ] && ok=$((ok+1)); echo "round $r publish_mtime=$pub miss_start=$s same_second=$([ "$pub" = "$s" ] && echo yes || echo no) record=$got"; done
echo "same-second-or-adjacent misses recorded: $ok/$n"
echo "== S4 concurrent timeouts count both"
ok=0; n=${ROUNDS:-6}
for r in $(seq 1 $n); do "$REAL_RM" -f "$H/state/.home-summary-refresh.backoff"; s=$(date +%s)
  stall & p=$!; stall; wait $p; got=$(rec); [ "$got" = 2 ] && ok=$((ok+1))
  echo "round $r misses=$got elapsed=$(( $(date +%s)-s ))s leftovers=$(left)"; done
echo "concurrent rounds counting both: $ok/$n"
echo "== S5 older miss cannot undo a newer success (success lands while the stalled attempt is running)"
ok=0; n=${SUP:-3}
for r in $(seq 1 $n); do "$REAL_RM" -f "$H/state/.home-summary-refresh.backoff"; g0=$(gen)
  stall & p=$!; sleep 1; run; wait $p; got=$(rec); [ "$got" = none ] && ok=$((ok+1))
  echo "round $r generation $g0 -> $(gen) record=$got leftovers=$(left)"; done
echo "superseded rounds with record clear: $ok/$n"
echo "== S6 reap stalls on a hung rm: caller still bounded"
s=$(date +%s); PATH="$RB:$SB:$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=3 "$W" --best-effort; echo "rc=$? elapsed=$(( $(date +%s)-s ))s (bound: 3s worker + 10s reap + 2s log)"
echo "load: $(uptime | sed 's/.*load/load/')"
