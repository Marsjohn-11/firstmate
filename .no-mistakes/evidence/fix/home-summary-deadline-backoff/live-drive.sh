#!/usr/bin/env bash
# Live driver: runs the real bin/fm-home-summary-refresh.sh against a disposable home.
set -u
ROOT=$1; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-hs-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
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
left() { find "$H/state" -maxdepth 1 \( -name '.home-summary.json.*' -o -name '.home-summary-error.*' \) | wc -l | tr -d ' '; }
run() { PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" "$W" "$@"; }
stall() { PATH="$SB:$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=${T:-3} "$W" --best-effort; }
echo "== S1 success publishes"; run; echo "rc=$? ledger=$(test -s "$H/state/home-summary.json" && echo yes) record=$(rec)"
echo "== S2 killed worker: bounded, reaped, counted"
for i in 1 2 3; do s=$(date +%s); stall; rc=$?; echo "attempt $i rc=$rc elapsed=$(( $(date +%s)-s ))s leftovers=$(left) record=$(rec)"; done
run; echo "after success: record=$(rec)"
echo "== S3 concurrent timeouts count both"
touch -t 200001010000 "$H/state/home-summary.json"
ok=0; n=${ROUNDS:-8}
for r in $(seq 1 $n); do "$REAL_RM" -f "$H/state/.home-summary-refresh.backoff"; s=$(date +%s)
  stall & p=$!; stall; wait $p; got=$(rec); [ "$got" = 2 ] && ok=$((ok+1))
  echo "round $r misses=$got elapsed=$(( $(date +%s)-s ))s leftovers=$(left)"; done
echo "concurrent rounds counting both: $ok/$n"
echo "== S4 superseded miss leaves record clear"
run; touch -t 203801010000 "$H/state/home-summary.json"; stall; echo "record=$(rec)"
echo "== S5 reap stalls on a hung rm: caller still bounded"
touch -t 200001010000 "$H/state/home-summary.json"
s=$(date +%s); PATH="$RB:$SB:$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=3 "$W" --best-effort; echo "rc=$? elapsed=$(( $(date +%s)-s ))s (bound: 3s worker + 5s reap)"
pkill -f "$RB/rm" 2>/dev/null; true
