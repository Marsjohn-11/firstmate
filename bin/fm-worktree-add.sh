#!/usr/bin/env bash
# Declare a package this task changes: add its worktree to the task's own
# Brazil workspace, or list the packages declared so far.
#
# Usage:
#   fm-worktree-add.sh <package>   add <package> at <shell>/src/<package>
#   fm-worktree-add.sh --list      print the declared packages
#
# Run from anywhere inside the task workspace (bin/fm-brazil-lib.sh owns the
# workspace contract); the script finds it by walking up from the current
# directory to the .fm-primary marker. The package must already be checked
# out in the primary workspace, and its worktree starts on branch fm-<id> at a
# fresh fetch of origin's default branch with that upstream set. A failed or
# timed-out fetch, a package from another workspace, and a leftover fm-<id>
# branch all refuse. Adding a package again is a no-op. Teardown checks every
# declared package for unlanded work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-brazil-lib.sh
. "$SCRIPT_DIR/fm-brazil-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-worktree-add.sh <package>
       fm-worktree-add.sh --list
  Add a package worktree to this task's Brazil workspace, or list the packages
  declared so far. Run from inside the task workspace.
EOF
  exit 2
}

LIST=0
PACKAGE=
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    -h | --help) usage ;;
    -*)
      echo "error: unknown flag '$1'" >&2
      usage
      ;;
    *)
      [ -z "$PACKAGE" ] || {
        echo "error: unexpected argument '$1'" >&2
        usage
      }
      PACKAGE=$1
      ;;
  esac
  shift
done

SHELL_DIR=$(pwd -P)
while [ "$SHELL_DIR" != / ] && [ ! -f "$SHELL_DIR/.fm-primary" ]; do
  SHELL_DIR=$(dirname "$SHELL_DIR")
done
if [ ! -f "$SHELL_DIR/.fm-primary" ]; then
  echo "error: not inside a task Brazil workspace (no .fm-primary marker in the current directory or any parent)" >&2
  exit 1
fi

if [ "$LIST" = 1 ]; then
  [ -z "$PACKAGE" ] || usage
  fm_brazil_shell_packages "$SHELL_DIR"
  exit 0
fi
[ -n "$PACKAGE" ] || usage

fm_brazil_add_package "$SHELL_DIR" "$PACKAGE"
