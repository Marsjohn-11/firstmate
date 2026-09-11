#!/usr/bin/env bash
# Record a CR-ready task: store one validated canonical cr=<url> in the task's
# metadata and surface the ready line, without arming any merge poll.
#
# This is the CRUX code-review analogue of bin/fm-pr-check.sh, but deliberately
# lighter. The CR rail always escalates: firstmate never auto-publishes or
# auto-merges a code review (AGENTS.md section 7), so there is no autonomous
# merge to detect and therefore no self-executing poll to arm. The whole job is
# to record the canonical CR URL as the ready signal and let firstmate escalate
# it to the captain.
#
# Only the canonical https://code.amazon.com/reviews/CR-<digits> URL is
# accepted (bin/fm-delivery-target-lib.sh). The metadata write is atomic and
# locked so a recorded cr= round-trips to exactly the URL it came from.
# Usage: fm-cr-check.sh <task-id> <cr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-delivery-target-lib.sh
. "$SCRIPT_DIR/fm-delivery-target-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid CR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_cr_url_parse "$RAW_URL"; then
  echo "error: invalid CR check request" >&2
  exit 2
fi
URL=$FM_CR_URL

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

META_TMP=
META_LOCK=
META_LOCK_HELD=0
cr_check_cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap cr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-cr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    cr=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'cr=%s\n' "$URL" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
RECORDED=$(grep '^cr=' "$META" | tail -1 | cut -d= -f2- || true)
[ "$RECORDED" = "$URL" ] || { echo "error: recorded CR URL did not round-trip" >&2; exit 1; }
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

# In a secondmate home the recorded CR is a captain-facing fact: publish the
# child's CR-ready line with the canonical URL so it reaches the parent whether
# or not the mate model appends anything (bin/fm-parent-channel-lib.sh). A main
# home has no channel and this is a silent no-op there.
READY_LINE="done [key=child-cr-$ID]: child $ID CR ready: $URL"
CR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$CR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$CR_MODE")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: CR %s is recorded but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'recorded: cr=%s\n' "$URL"
