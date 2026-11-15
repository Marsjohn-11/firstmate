#!/usr/bin/env bash
# Live lab: parent lab home + remote lab home reached over real ssh localhost.
set -u
ROOT=$1; OUT=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
RH=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-remote.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$RH" >/dev/null
JOBS=$(mktemp -d /tmp/fm-lab-jobs.XXXXXX); CLAIMS=$LAB/claims; mkdir -p "$CLAIMS"
SHIM=$LAB/ssh-shim
cat > "$SHIM" <<SH
#!/usr/bin/env bash
# Real ssh to localhost; the remote entrypoint is addressed by its checkout path
# and the remote job state root is kept inside the lab.
while [ "\$#" -gt 0 ]; do case "\$1" in -o) shift 2;; --) shift; break;; *) exit 90;; esac; done
host=\$1; entry=\$2; shift 2
argv=\$(printf '%s' "\$4" | base64 -d 2>/dev/null | tr '\0\n' '  ')
case "\$argv" in *fm-remote-secondmate-control.sh*state*) echo alive; exit 0;;
  *fm-remote-secondmate-control.sh*relaunch*) cat >/dev/null; set -- \$argv; printf 'schema=fm-remote-secondmate-control.v1\nbackend=herdr\ntarget=fm-remote:w1:p1\nherdr_session=fm-remote\nharness=%s\nmodel=%s\neffort=%s\n' "\$4" "\$5" "\$6"; exit 0;; esac
printf '%s\n' "ssh \$host \$argv" >> "$LAB/ssh.log"
exec /usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=no "\$host" \
  "env FM_REMOTE_JOB_STATE_ROOT=$JOBS FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux $ROOT/bin/fm-remote-entrypoint.sh \$(printf '%q ' "\$@")"
SH
chmod +x "$SHIM"
export FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$CLAIMS FM_SSH_BIN=$SHIM FM_REMOTE_REPLY_WAIT_SECONDS=5
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
A=$ROOT/bin/fm-procevent-remote-reply.sh
log() { printf '\n$ %s\n' "$*" >> "$OUT"; }
run() { log "$*"; "$@" >> "$OUT" 2>&1; printf '[exit %s]\n' "$?" >> "$OUT"; }
cleanup() {
  "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
  [ -f "$JOBS/worker.pid" ] && { . "$ROOT/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$(cat "$JOBS/worker.pid")"; } >/dev/null 2>&1
  pkill -f "$LAB" 2>/dev/null; rm -rf "$LAB" "$RH" "$JOBS"
}
trap cleanup EXIT
printf -- '- mega - heavy offload (host: localhost; root: %s; home: %s; scope: offload; projects: alpha; added 2026-11-10)\n' "$ROOT" "$RH" > "$LAB/data/secondmates.md"
. "$ROOT/bin/fm-meta-lib.sh" 2>/dev/null || true
cat > "$LAB/state/mega.meta" <<M
window=remote:mega
endpoint_task_id=mega
worktree=$RH/never-local
harness=claude
kind=secondmate
mode=secondmate
remote_host=localhost
remote_root=$ROOT
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
M
SID=$("$A" source-id mega)
listen() { for _ in $(seq 1 ${2:-200}); do grep -Fq -- "$1" "$LAB/state/mega.status" 2>/dev/null && return 0; "$ROOT/bin/fm-procevent.sh" ensure-listening "$SID" >/dev/null 2>&1; sleep 0.3; done; return 1; }
showstatus() { log "cat \$FM_HOME/state/mega.status"; cat "$LAB/state/mega.status" >> "$OUT" 2>/dev/null; }

echo "### Relaunch R1: intact log stays armed at its cursor" >> "$OUT"
printf 'working: first host is up\nneeds-decision [key=q1]: pick a cache size\n' > "$RH/state/parent-replies.status"
run "$A" rebase mega --if-moved
run "$A" arm mega
listen 'needs-decision [key=q1]' && echo "(mirrored)" >> "$OUT" || echo "(NOT mirrored)" >> "$OUT"
showstatus
run "$A" registered mega
run "$ROOT/bin/fm-remote-secondmate-relaunch.sh" mega codex default medium
run "$A" registered mega
grep -E '^(harness|effort)=' "$LAB/state/mega.meta" >> "$OUT"


echo "### Relaunch R2: desk rebuilt with a new log, relaunch rebases; only new lines mirrored" >> "$OUT"
pid=$(sed -n '2p' "$CLAIMS/$SID.claim" 2>/dev/null); [ -n "$pid" ] && kill -TERM -- -"$pid" 2>/dev/null; sleep 1
printf 'note: rebuilt on a new host\nworking: first host is up\nworking: caught up after the move\n' > "$RH/state/parent-replies.status"
B=$(grep -cF 'working: first host is up' "$LAB/state/mega.status")
run "$ROOT/bin/fm-remote-secondmate-relaunch.sh" mega claude default high
run "$A" registered mega
listen 'working: caught up after the move' && echo "(new lines mirrored)" >> "$OUT"
showstatus
echo "(count of already-mirrored line before=$B after=$(grep -cF 'working: first host is up' "$LAB/state/mega.status"))" >> "$OUT"
log "ssh transport log"; sort "$LAB/ssh.log" | uniq -c >> "$OUT"
