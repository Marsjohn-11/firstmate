#!/usr/bin/env bash
# Print a project's delivery rail: "crux-cr" or "forge".
#
# The rail is derived from the origin host (bin/fm-delivery-target-lib.sh):
# an Amazon gitfarm origin ships via a CRUX code review, everything else via a
# forge PR/MR. With a directory argument the origin is read from that git
# working copy; with --origin the URL is classified directly without a clone.
# An unreadable or absent origin resolves to "forge", never the CR rail.
# Usage: fm-delivery-target.sh <project-dir>
#        fm-delivery-target.sh --origin <url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-delivery-target-lib.sh
. "$SCRIPT_DIR/fm-delivery-target-lib.sh"

case "${1:-}" in
  -h|--help)
    awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
    exit 0 ;;
  --origin)
    [ "$#" -eq 2 ] || { echo "error: --origin requires a URL" >&2; exit 2; }
    fm_delivery_target_from_origin "$2"
    exit 0 ;;
  '' )
    echo "error: usage: fm-delivery-target.sh <project-dir> | --origin <url>" >&2
    exit 2 ;;
  -* )
    echo "error: unknown option: $1" >&2
    exit 2 ;;
esac

[ -d "$1" ] || { echo "error: not a directory: $1" >&2; exit 2; }
fm_delivery_target_of_dir "$1"
