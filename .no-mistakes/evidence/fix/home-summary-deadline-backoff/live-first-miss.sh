#!/usr/bin/env bash
# Live: first deadline miss right after a success. GAP=seconds between the
# success and the stalled attempt. Reports whether the miss was recorded.
set -u
ROOT=$1; GAP=${GAP:-0}; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-hs-lab.XXXXXX"); trap 'pkill -KILL -f "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
W="$ROOT/bin/fm-home-summary-refresh.sh"; H="$LAB/home"; FB="$LAB/fakebin"; SB="$LAB/stubborn"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects" "$FB" "$SB"
printf '# home\n' > "$H/AGENTS.md"; printf 'lab\n' > "$H/.fm-secondmate-home"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
printf '#!/usr/bin/env bash\ncase "${1:-}" in display-message) printf "%%%%1\\n";; capture-pane) printf "p\\n> \\n";; esac\nexit 0\n' > "$FB/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
REAL_JQ=$(command -v jq); export REAL_JQ
cat > "$SB/jq" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in */.home-summary.json.*) trap '' TERM; while :; do sleep 0.1; done;; esac; done
exec "$REAL_JQ" "$@"
SH
chmod +x "$FB"/* "$SB/jq"
for r in 1 2 3 4; do
  rm -f "$H/state/.home-summary-refresh.backoff"
  PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" "$W"
  pub=$(stat -f %m "$H/state/home-summary.json"); sleep "$GAP"
  start=$(date +%s)
  PATH="$SB:$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=3 "$W" --best-effort 2>/dev/null
  echo "round $r gap=${GAP}s ledger_mtime-attempt_start=$((pub-start))s record=$(cat "$H/state/.home-summary-refresh.backoff" 2>/dev/null || echo none)"
done
