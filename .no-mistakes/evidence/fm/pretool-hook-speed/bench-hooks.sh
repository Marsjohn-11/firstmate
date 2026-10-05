#!/usr/bin/env bash
# Per-call wall time of base vs head hooks on Claude-shaped payloads, optionally under CPU load.
T=$1; N=${2:-30}; LOAD=${3:-0}
pids=(); if [ "$LOAD" -gt 0 ]; then for ((i=0;i<LOAD;i++)); do (while :; do :; done) & pids+=($!); done; fi
trap 'kill ${pids[@]} 2>/dev/null' EXIT
mk() { jq -cn --arg t "$1" --rawfile b <(head -c "$2" /dev/zero | tr '\0' 'x' | fold -w 70) --arg c "$3" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{command:$c,content:$b,file_path:"/tmp/f"}}'; }
P1=$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls -la && git status"}}')
P2=$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"cd /tmp && ls"}}')
P3=$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:"/tmp/f"}}')
P4=$(mk Write 16000 "")
P5=$(mk Write 1000000 "")
P6=$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Task",tool_input:{prompt:"do it"}}')
bench() { local d=$1 s=$2 p=$3 t0 t1; t0=$(date +%s%N); for ((i=0;i<N;i++)); do printf '%s' "$p" | (cd $T/$d && env -u FM_ROOT_OVERRIDE bin/$s --claude >/dev/null 2>&1); done; t1=$(date +%s%N); echo $(( (t1-t0)/N/1000000 )); }
printf '%-38s %8s %8s\n' "case (load=$LOAD busy loops, N=$N)" base_ms head_ms
for c in "cd-guard Bash 'ls -la && git status'|fm-cd-pretool-check.sh|$P1" "cd-guard Bash 'cd /tmp && ls' (deny)|fm-cd-pretool-check.sh|$P2" "subagent Read|fm-subagent-pretool-check.sh|$P3" "subagent Write 16KB|fm-subagent-pretool-check.sh|$P4" "subagent Write 1MB|fm-subagent-pretool-check.sh|$P5" "subagent Task (deny)|fm-subagent-pretool-check.sh|$P6" "cd-guard Read (non-Bash payload)|fm-cd-pretool-check.sh|$P3"; do
  name=${c%%|*}; r=${c#*|}; s=${r%%|*}; p=${r#*|}
  printf '%-38s %8s %8s\n' "$name" "$(bench base $s "$p")" "$(bench head $s "$p")"
done
