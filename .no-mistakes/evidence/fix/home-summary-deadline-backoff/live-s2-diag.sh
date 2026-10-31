#!/usr/bin/env bash
# S2 diagnostic: sequential deadline misses with a process dump when an attempt runs past 40s.
set -u
ROOT=$1; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-hs-lab.XXXXXX"); trap 'pkill -KILL -f "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
W="$ROOT/bin/fm-home-summary-refresh.sh"; H="$LAB/home"; FB="$LAB/fakebin"; SB="$LAB/stubborn"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects" "$FB" "$SB"
printf '# home\n' > "$H/AGENTS.md"; printf 'lab\n' > "$H/.fm-secondmate-home"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
printf '#!/usr/bin/env bash\ncase "${1:-}" in display-message) printf "%%%%1\\n";; capture-pane) printf "p\\n> \\n";; esac\nexit 0\n' > "$FB/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
export REAL_JQ=$(command -v jq)
cat > "$SB/jq" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in */.home-summary.json.*) trap '' TERM; while :; do sleep 0.1; done;; esac; done
exec "$REAL_JQ" "$@"
SH
chmod +x "$FB"/* "$SB/jq"
rec() { cat "$H/state/.home-summary-refresh.backoff" 2>/dev/null || echo none; }
PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" "$W"; echo "seed rc=$? record=$(rec)"
for i in 1 2 3 4; do
  s=$(date +%s)
  PATH="$SB:$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=3 "$W" --best-effort & p=$!
  while kill -0 $p 2>/dev/null; do
    if [ $(( $(date +%s)-s )) -ge 40 ]; then echo "attempt $i HUNG; tree:"; ps -axo pid,ppid,pgid,stat,etime,command | grep -F "$LAB" | grep -v grep | cut -c1-220; ls -la "$H/state"; kill -KILL $p; break; fi
    sleep 1; done
  wait $p; echo "attempt $i rc=$? elapsed=$(( $(date +%s)-s ))s record=$(rec) lock=$(ls -d "$H/state/.home-summary-refresh.lock" 2>/dev/null)"
  tail -2 "$H/state/.home-summary-refresh.log" 2>/dev/null
done
