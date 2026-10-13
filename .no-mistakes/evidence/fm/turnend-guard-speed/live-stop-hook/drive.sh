#!/bin/bash
# drive.sh <home> <label> : run the Claude Stop hook command for <home> N times, report exit, stderr, median ms
home=$1; label=$2; n=${3:-5}
cmd=$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["hooks"]["Stop"][0]["hooks"][0]["command"])' "$home/.claude/settings.json")
payload='{"session_id":"live-lab","transcript_path":"/dev/null","cwd":"'"$home"'","hook_event_name":"Stop","stop_hook_active":false}'
times=()
for i in $(seq $n); do
  s=$(python3 -c 'import time;print(int(time.time()*1000))')
  err=$(cd "$home" && printf '%s' "$payload" | env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$home" CLAUDE_PROJECT_DIR="$home" CLAUDECODE=1 sh -c "$cmd" 2>&1 >/dev/null); rc=$?
  e=$(python3 -c 'import time;print(int(time.time()*1000))')
  times+=($((e-s)))
done
sorted=$(printf '%s\n' "${times[@]}" | sort -n | tr '\n' ' ')
echo "[$label] exit=$rc times_ms=[$sorted]"
printf "%s\n" "$err" > "$(dirname "$0")/out-$label.txt"; echo "[$label] stderr: $(printf "%s" "$err" | head -c 200 | tr "\n" " ")"
