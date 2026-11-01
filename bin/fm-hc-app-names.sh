#!/usr/bin/env bash
# fm-hc-app-names.sh - name this home's existing hc task tabs in Herdr.app.
#
# Usage: fm-hc-app-names.sh [--spaces]
#
# A new hc task terminal names its own Herdr.app tab at spawn
# (bin/backends/hc.sh fm_backend_hc_app_name). This names the tabs of task
# terminals that already run, one per live hc task record in FM_HOME's state,
# after the task id. The tab and space ids are read from the terminal's own
# herdr.tab and herdr.space labels. --spaces also names each space after its
# home (firstmate, 2ndmate-<id>), replacing whatever name it has.
# Only terminals on hc's `default` session are shown by the app, so others are
# skipped, and with no open window nothing happens. Prints one line per task
# it asked the app to name; never fails a caller.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
case "${1:-}" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --spaces) SPACES=1 ;;
  '') SPACES=0 ;;
  *) echo "usage: fm-hc-app-names.sh [--spaces]" >&2; exit 2 ;;
esac
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || { echo "error: FM_HOME is not a firstmate home" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source hc || exit 0

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  [ "$(fm_backend_of_meta "$meta")" = hc ] || continue
  id=$(basename "$meta" .meta)
  target=$(fm_meta_get "$meta" window)
  fm_backend_hc_parse_target "$target" || continue
  [ "$FM_BACKEND_HC_SESSION" = default ] || continue
  labels=$(fm_backend_hc_get "$target" | jq -r '[.state // "", .labels["herdr.space"] // "", .labels["herdr.tab"] // ""] | @tsv' 2>/dev/null) || continue
  IFS=$'\t' read -r state space tab <<LABELS
$labels
LABELS
  [ "$state" = live ] && [ -n "$space" ] && [ -n "$tab" ] || continue
  FM_HC_APP_NAME_TRIES=1 fm_backend_hc_app_name default "$space" "$tab" "$id" "$SPACES"
  echo "requested $id tab=$tab space=$space"
done
exit 0
