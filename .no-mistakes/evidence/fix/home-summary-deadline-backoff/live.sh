#!/usr/bin/env bash
# Live scenarios for fm-home-summary-refresh.sh / fm-watch.sh backoff on a disposable home.
set -u
ROOT=$1
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"; WATCH="$ROOT/bin/fm-watch.sh"
T=$(mktemp -d /tmp/fm-live.XXXXXX); T=$(cd "$T" && pwd -P)
FAKE="$T/fake"; mkdir -p "$FAKE"
printf '#!/usr/bin/env bash\ncase "${1:-}" in display-message) printf "%%%%1\\n";; capture-pane) printf "pane\\n> \\n";; esac\nexit 0\n' > "$FAKE/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/no-mistakes"
chmod +x "$FAKE"/*
REAL_JQ=$(command -v jq); REAL_HEAD=$(command -v head)
WPID=
trap '[ -n "$WPID" ] && kill -KILL $WPID 2>/dev/null; rm -rf "$T"' EXIT
mkhome() { local h="$T/$1"; mkdir -p "$h/state" "$h/data" "$h/config" "$h/projects"
  printf '# home\n' > "$h/AGENTS.md"; printf '%s\n' "$1" > "$h/.fm-secondmate-home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"; echo "$h"; }
run() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE PATH="$FAKE:$PATH" "$@"; }
# stubborn validation: ignores TERM so the worker is KILLed at its deadline
SB="$T/stubborn"; mkdir -p "$SB"
cat > "$SB/jq" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in */.home-summary.json.*) trap '' TERM; : > "$FM_LIVE_MARK.$$"; sleep 60;; esac; done
exec "$FM_LIVE_REAL_JQ" "$@"
SH
# stalled state fs for the reap child's record read: head on the backoff record hangs, ignoring TERM
STALL="$T/stall"; mkdir -p "$STALL"; cp "$SB/jq" "$STALL/jq"
cat > "$STALL/head" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *.home-summary-refresh.backoff) trap '' TERM; : > "$FM_LIVE_MARK.headstall"; sleep 120;; esac; done
exec "$FM_LIVE_REAL_HEAD" "$@"
SH
chmod +x "$SB"/* "$STALL"/*
res() { printf '%-6s %s\n' "$1" "$2"; }

echo "== S1: parent reap/backoff writes are bounded when the state fs stalls"
H=$(mkhome s1); s=$(date +%s)
run PATH="$STALL:$FAKE:$PATH" FM_LIVE_REAL_JQ="$REAL_JQ" FM_LIVE_REAL_HEAD="$REAL_HEAD" FM_LIVE_MARK="$T/m1" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=3 "$WRITER" --best-effort; rc=$?
el=$(( $(date +%s) - s ))
echo "writer rc=$rc elapsed=${el}s head-stall-reached=$([ -e "$T/m1.headstall" ] && echo yes || echo no)"
echo "error log:"; cat "$H/state/.home-summary-refresh.log" 2>/dev/null | sed 's/^/  /'
[ $rc -eq 0 ] && [ $el -lt 12 ] && [ -e "$T/m1.headstall" ] && res PASS S1 || res FAIL S1

echo "== S2: two concurrent timed-out parents count both misses (no lost increment)"
ok=1
for round in 1 2 3; do
  H=$(mkhome s2-$round)
  for p in a b; do run PATH="$SB:$FAKE:$PATH" FM_LIVE_REAL_JQ="$REAL_JQ" FM_LIVE_MARK="$T/m2" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=4 "$WRITER" --best-effort & done; wait
  # second parent may have waited on the lock and timed out too; each attempt that missed must count
  n=$(cat "$H/state/.home-summary-refresh.backoff" 2>/dev/null); left=$(ls -a "$H/state" | grep -c '^\.home-summary\.json\.\|^\.home-summary-error\.')
  echo "round $round: backoff record=$n leftover tmp files=$left"
  [ "$n" = 2 ] && [ "$left" = 0 ] || ok=0
done
[ $ok = 1 ] && res PASS S2 || res FAIL S2

echo "== S3: a newer success is not undone by an older timed-out attempt"
ok=1
for round in 1 2 3; do
  H=$(mkhome s3-$round); printf '1\n' > "$H/state/.home-summary-refresh.backoff"; rm -f "$T"/m3.*
  run PATH="$SB:$FAKE:$PATH" FM_LIVE_REAL_JQ="$REAL_JQ" FM_LIVE_MARK="$T/m3" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=4 "$WRITER" --best-effort & A=$!
  i=0; while ! ls "$T"/m3.* >/dev/null 2>&1 && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
  # B starts while A is stalled holding the lock, publishes right after A is killed
  run FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" "$WRITER" --best-effort & B=$!
  wait $A; wait $B
  pub=$([ -s "$H/state/home-summary.json" ] && jq -r .schema "$H/state/home-summary.json")
  echo "round $round: ledger=$pub backoff record=$(cat "$H/state/.home-summary-refresh.backoff" 2>/dev/null || echo absent)"
  [ "$pub" = fm-secondmate-home-summary.v1 ] && [ ! -e "$H/state/.home-summary-refresh.backoff" ] || ok=0
done
[ $ok = 1 ] && res PASS S3 || res FAIL S3

watch_probe() { # <home> <interval> -> runs watcher ~5s, prints whether ledger was republished
  local h=$1 iv=$2 before
  before=$(jq -r .generated_epoch "$h/state/home-summary.json")
  run FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" FM_POLL=1 FM_HOME_SUMMARY_INTERVAL="$iv" FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 "$WATCH" > "$h/watch.out" 2> "$h/watch.err" & WPID=$!
  sleep 6; alive=$(kill -0 $WPID 2>/dev/null && echo alive || echo exited)
  kill $WPID 2>/dev/null; wait $WPID 2>/dev/null; WPID=
  sleep 1
  echo "$alive $([ "$(jq -r .generated_epoch "$h/state/home-summary.json")" != "$before" ] && echo refreshed || echo held)"
}
seed() { local h=$1; run FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" FM_SNAPSHOT_NOW=2020-01-01T00:00:00Z FM_SNAPSHOT_NOW_EPOCH=1577836800 "$WRITER"
  touch -t 200001010000 "$h/state/home-summary.json"; }
backdate() { perl -e 'utime time-$ARGV[0], time-$ARGV[0], $ARGV[1]' "$1" "$2"; }

echo "== S4: zero-padded interval 0300 backs off 300s (decimal), not 192s (octal)"
H=$(mkhome s4); seed "$H"; printf '1\n' > "$H/state/.home-summary-refresh.backoff"; backdate 250 "$H/state/.home-summary-refresh.backoff"
r=$(watch_probe "$H" 0300); echo "miss 250s ago, interval 0300: watcher $r"
H2=$(mkhome s4b); seed "$H2"; printf '1\n' > "$H2/state/.home-summary-refresh.backoff"; backdate 310 "$H2/state/.home-summary-refresh.backoff"
r2=$(watch_probe "$H2" 0300); echo "miss 310s ago, interval 0300: watcher $r2; record now $(cat "$H2/state/.home-summary-refresh.backoff" 2>/dev/null || echo absent)"
[ "$r" = "alive held" ] && [ "$r2" = "alive refreshed" ] && res PASS S4 || res FAIL S4

echo "== S5: interval 09 and record '08' do not crash the watcher (base-10 parsing)"
H=$(mkhome s5); seed "$H"; printf '08\n' > "$H/state/.home-summary-refresh.backoff"
r=$(watch_probe "$H" 09); echo "interval 09, record 08 fresh: watcher $r"; tail -3 "$H/watch.err" | sed 's/^/  err: /'
[ "$r" = "alive held" ] && res PASS S5 || res FAIL S5
echo "== S5b: reap child increments a zero-padded '08' record to 9"
H=$(mkhome s5b); printf '08\n' > "$H/state/.home-summary-refresh.backoff"
run PATH="$SB:$FAKE:$PATH" FM_LIVE_REAL_JQ="$REAL_JQ" FM_LIVE_MARK="$T/m5" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_HOME_SUMMARY_TIMEOUT=3 "$WRITER" --best-effort
n=$(cat "$H/state/.home-summary-refresh.backoff"); echo "record after miss: $n"
[ "$n" = 9 ] && res PASS S5b || res FAIL S5b
