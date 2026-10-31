#!/usr/bin/env bash
set -u
ROOT=$1; WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
T=$(mktemp -d /tmp/fm-s2.XXXXXX); trap 'rm -rf "$T"' EXIT
FAKE="$T/fake"; SB="$T/sb"; mkdir -p "$FAKE" "$SB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/tmux"; cp "$FAKE/tmux" "$FAKE/no-mistakes"
cat > "$SB/jq" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in */.home-summary.json.*) trap '' TERM; echo "$(date +%s.%N 2>/dev/null) stall pid=$$ ppid=$PPID" >> "$FM_LIVE_TRACE"; sleep 60;; esac; done
exec "$FM_LIVE_REAL_JQ" "$@"
SH
chmod +x "$FAKE"/* "$SB"/*
for round in 1 2 3 4; do
  H="$T/h$round"; mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"; printf 'x\n' > "$H/.fm-secondmate-home"; printf '#\n' > "$H/AGENTS.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
  for p in a b; do env -u FM_ROOT_OVERRIDE PATH="$SB:$FAKE:$PATH" FM_LIVE_REAL_JQ="$(command -v jq)" FM_LIVE_TRACE="$T/trace$round" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=4 "$WRITER" --best-effort 2>/dev/null & done; wait
  echo "round $round: stalls=$(wc -l < "$T/trace$round" 2>/dev/null) record=$(cat "$H/state/.home-summary-refresh.backoff" 2>/dev/null || echo absent) lock=$(ls -ld "$H/state/.home-summary-refresh.lock" 2>/dev/null | awk '{print $1}') lockpid=$(cat "$H/state/.home-summary-refresh.lock/pid" 2>/dev/null)"
  sed 's/^/   log: /' "$H/state/.home-summary-refresh.log"
done
