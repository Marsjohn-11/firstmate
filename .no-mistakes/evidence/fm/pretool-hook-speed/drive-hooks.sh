#!/usr/bin/env bash
# Drive real base vs head hook scripts with Claude-shaped PreToolUse payloads in disposable plain clones.
T=$1
env_clean() { env -u FM_ROOT_OVERRIDE -u CLAUDE_PROJECT_DIR -u FM_SUBAGENT_GUARD_BYPASS "$@"; }
bash_payload() { jq -cn --arg c "$1" '{session_id:"s",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}'; }
tool_payload() { jq -cn --arg t "$1" --rawfile body <(printf '%s' "$2") '{session_id:"s",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{content:$body,file_path:"/tmp/x"}}'; }
run() { # dir script payload -> "rc|stdout|stderr-head"
  local o e rc; o=$(printf '%s' "$3" | (cd "$1" && env_clean bin/$2 --claude 2>/tmp/fmhook.err)); rc=$?; e=$(head -c 160 /tmp/fmhook.err | tr '\n' ' ')
  echo "rc=$rc out=${#o}B err=${e:0:120}"
}
echo "### cd guard decisions (base vs head)"
CMDS=( "ls -la" "git status" "cd /tmp" "cd /tmp && ls" "pushd /tmp" "popd" "c'd' /tmp" "c\"d\" /tmp" "c\\d /tmp" $'c\\\nd /tmp' "\$'\\x63d' /tmp" "npx cdk deploy" "echo abcd" "ls /mnt/cdrom" "(cd sub; make)" "echo hi; cd .." "builtin cd /" "env cd /" )
mism=0
for c in "${CMDS[@]}"; do
  p=$(bash_payload "$c"); b=$(run $T/base fm-cd-pretool-check.sh "$p"); h=$(run $T/head fm-cd-pretool-check.sh "$p")
  [ "${b%% out*}" = "${h%% out*}" ] && m=same || { m=MISMATCH; mism=$((mism+1)); }
  printf '%-22q base[%s] head[%s] %s\n' "$c" "${b%% err*}" "${h%% err*}" "$m"
done
echo "cd mismatches: $mism"
echo
echo "### subagent guard decisions (base vs head)"
TOOLS=( Read Bash Write Edit Grep Glob TodoWrite WebFetch Task Agent "agent" "Sub_Agent" "spawn-worker" "mcp__foo__task" "TaskCreate" "Explore" "ExitPlanMode" "Delegate" "launch_subagent" )
mism=0
for t in "${TOOLS[@]}"; do
  p=$(tool_payload "$t" "hello"); b=$(run $T/base fm-subagent-pretool-check.sh "$p"); h=$(run $T/head fm-subagent-pretool-check.sh "$p")
  [ "${b%% out*}" = "${h%% out*}" ] && m=same || { m=MISMATCH; mism=$((mism+1)); }
  printf '%-18s base[%s] head[%s] %s\n' "$t" "${b%% err*}" "${h%% err*}" "$m"
done
# adversarial: delegation stem word inside content of a non-delegating tool must still allow; and delegating tool with big content still denies
big=$(head -c 300000 /dev/urandom | base64 -w 76 | tr -d 0-9 | tr 'A-Z' 'a-z')
for t in Write Task; do p=$(tool_payload "$t" "$big"); b=$(run $T/base fm-subagent-pretool-check.sh "$p"); h=$(run $T/head fm-subagent-pretool-check.sh "$p"); echo "$t+400KB-content base[${b%% err*}] head[${h%% err*}]"; done
p=$(tool_payload Write "please spawn a subagent task delegate agent"); b=$(run $T/base fm-subagent-pretool-check.sh "$p"); h=$(run $T/head fm-subagent-pretool-check.sh "$p"); echo "Write+stem-words base[${b%% err*}] head[${h%% err*}]"
p='{"tool_name":"\u0054ask","tool_input":{}}'; b=$(run $T/base fm-subagent-pretool-check.sh "$p"); h=$(run $T/head fm-subagent-pretool-check.sh "$p"); echo "unicode-escaped-Task base[${b%% err*}] head[${h%% err*}]"
p='{"tool_name":"Bash","tool_input":{"command":"\u0063d /tmp"}}'; b=$(run $T/base fm-cd-pretool-check.sh "$p"); h=$(run $T/head fm-cd-pretool-check.sh "$p"); echo "unicode-escaped-cd base[${b%% err*}] head[${h%% err*}]"
echo "subagent mismatches: $mism"
