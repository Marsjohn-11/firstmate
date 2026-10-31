#!/usr/bin/env bash
# Live watcher driver: real bin/fm-watch.sh against a disposable home, checking
# that zero-padded intervals and miss counts read as decimal in the backoff.
set -u
ROOT=$1; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-hs-lab.XXXXXX")
WP=; trap '[ -n "$WP" ] && kill -KILL $WP 2>/dev/null; pkill -KILL -f "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
FB="$LAB/fakebin"; mkdir -p "$FB"
printf '#!/usr/bin/env bash\ncase "${1:-}" in display-message) printf "%%%%1\\n";; capture-pane) printf "p\\n> \\n";; esac\nexit 0\n' > "$FB/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"; chmod +x "$FB"/*
case_run() {  # <name> <interval> <misses> <record-age-s> <expect: hold|refresh>
  local name=$1 iv=$2 m=$3 age=$4 want=$5 H="$LAB/$1" i got
  mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"
  printf '# home\n' > "$H/AGENTS.md"; printf '%s\n' "$name" > "$H/.fm-secondmate-home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
  PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_SNAPSHOT_NOW=2026-08-28T10:01:00Z FM_SNAPSHOT_NOW_EPOCH=1787911260 "$ROOT/bin/fm-home-summary-refresh.sh"
  touch -t 203801010000 "$H/state/home-summary.json"
  printf '%s\n' "$m" > "$H/state/.home-summary-refresh.backoff"
  perl -e 'utime(time-$ARGV[0], time-$ARGV[0], $ARGV[1])' "$age" "$H/state/.home-summary-refresh.backoff"
  PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" \
    FM_SNAPSHOT_NOW=2026-08-28T10:02:00Z FM_SNAPSHOT_NOW_EPOCH=1787911320 \
    FM_POLL=1 FM_HOME_SUMMARY_INTERVAL="$iv" FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$ROOT/bin/fm-watch.sh" > "$LAB/$name.out" 2> "$LAB/$name.err" & WP=$!
  i=0; while [ ! -e "$H/state/.last-watcher-beat" ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
  i=0; got=hold
  while [ $i -lt ${WAIT:-150} ]; do
    kill -0 $WP 2>/dev/null || { got="watcher-exited: $(tail -2 "$LAB/$name.err")"; break; }
    jq -e '.generated == "2026-08-28T10:02:00Z"' "$H/state/home-summary.json" >/dev/null 2>&1 && { got=refresh; break; }
    sleep 0.1; i=$((i+1)); done
  kill -0 $WP 2>/dev/null && alive=alive || alive=dead
  echo "$name: FM_HOME_SUMMARY_INTERVAL=$iv record=$m aged ${age}s -> $got (want $want, record age at verdict $(( $(date +%s) - $(stat -f %m "$H/state/.home-summary-refresh.backoff" 2>/dev/null || date +%s) ))s), watcher $alive, record now: $(cat "$H/state/.home-summary-refresh.backoff" 2>/dev/null || echo cleared)"
  kill $WP 2>/dev/null; wait $WP 2>/dev/null; WP=
}
case_run pad3000 03000 1 2000 hold
case_run pad08  08   1 100 refresh
case_run misses08 0300 08 1000 hold
case_run oct0300 0300 1 250 hold
case_run base   300  1 400 refresh
