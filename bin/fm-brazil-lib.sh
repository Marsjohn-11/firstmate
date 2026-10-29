# shellcheck shell=bash
# Per-task Brazil workspace isolation.
#
# A Brazil workspace is a directory with a `packageInfo` file or a `.brazil/`
# directory at its root, holding one git repository per package under
# `src/<Package>`. A project is a Brazil package when its repository's primary
# checkout sits at `<workspace>/src/<Package>`.
#
# bin/fm-spawn.sh gives every fresh ship or scout on such a project its own
# workspace, built with `brazil-worktree create --empty` at
# `<workspace>/worktrees/fm-<id>` (the task's workspace shell), and adds the
# project's own package there. The task's worktree= is that package worktree,
# `<shell>/src/<Package>`, and the task record also carries project_kind=brazil
# and workspace_shell=<shell>. The worker declares every other package it
# changes with bin/fm-worktree-add.sh. bin/fm-teardown.sh checks every declared
# package for unlanded work before `brazil-worktree remove` deletes the shell.
#
# Shell contract, read by spawn's relaunch, teardown, and fm-worktree-add.sh:
#   <shell>/.fm-primary   the primary workspace's real path
#   <shell>/.fm-packages  declared packages, one per line, the project's first
#
# brazil-worktree names each package's branch after the shell (fm-<id>),
# reuses an existing branch of that name, and deletes it on remove. On a
# package the primary lacks, addPackage runs a Brazil checkout in the PRIMARY
# workspace, so fm_brazil_add_package refuses both cases before calling it.
#
# Every tool and network call is bounded (bin/fm-timeout-lib.sh):
# FM_BRAZIL_TOOL_TIMEOUT (default 300s) for brazil-worktree, and
# FM_BRAZIL_FETCH_TIMEOUT (default 60s) for each origin round trip.
#
# Sourced; callers already run under `set -eu`. Functions print errors to
# stderr and return non-zero rather than exiting.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_BRAZIL_TOOL_OUTPUT=
FM_BRAZIL_PRIMARY=
FM_BRAZIL_PACKAGE=

# fm_brazil_is_workspace <dir>: 0 when <dir> is a Brazil workspace root.
fm_brazil_is_workspace() {
  local dir=$1
  [ -d "$dir" ] || return 1
  [ -f "$dir/packageInfo" ] || [ -d "$dir/.brazil" ]
}

# fm_brazil_package_project <project>: 0 when <project>'s repository has its
# primary checkout at <workspace>/src/<Package> inside a Brazil workspace. Sets
# FM_BRAZIL_PRIMARY to the workspace's real path and FM_BRAZIL_PACKAGE to the
# package name. A linked worktree of the package resolves to the same answer.
fm_brazil_package_project() {
  local project=$1 common pkg_dir src_dir ws
  FM_BRAZIL_PRIMARY=
  FM_BRAZIL_PACKAGE=
  common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$(basename "$common")" = .git ] || return 1
  pkg_dir=$(cd "$(dirname "$common")" 2>/dev/null && pwd -P) || return 1
  src_dir=$(dirname "$pkg_dir")
  [ "$(basename "$src_dir")" = src ] || return 1
  ws=$(dirname "$src_dir")
  fm_brazil_is_workspace "$ws" || return 1
  FM_BRAZIL_PRIMARY=$ws
  FM_BRAZIL_PACKAGE=$(basename "$pkg_dir")
}

# fm_brazil_shell_path <primary> <task-id>: the task's workspace shell path.
fm_brazil_shell_path() {
  printf '%s/worktrees/fm-%s\n' "$1" "$2"
}

# fm_brazil_shell_primary <shell>: prints the primary recorded in the shell.
fm_brazil_shell_primary() {
  local marker="$1/.fm-primary" primary
  [ -f "$marker" ] || return 1
  primary=$(head -n 1 "$marker") || return 1
  [ -n "$primary" ] || return 1
  printf '%s\n' "$primary"
}

# fm_brazil_shell_packages <shell>: prints the declared packages, one per line.
fm_brazil_shell_packages() {
  local list="$1/.fm-packages" package
  [ -f "$list" ] || return 0
  while IFS= read -r package || [ -n "$package" ]; do
    [ -z "$package" ] || printf '%s\n' "$package"
  done < "$list"
}

_fm_brazil_timeout() {  # <env-value> <default> <name>
  local value=${1:-$2}
  case "$value" in
    '' | 0* | *[!0-9]*)
      echo "fm-brazil-lib: $3 must be a positive number of seconds, got '$value'" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$value"
}

# _fm_brazil_tool <args...>: one bounded brazil-worktree call. Its combined
# output is kept in FM_BRAZIL_TOOL_OUTPUT for the caller's diagnostic.
_fm_brazil_tool() {
  local timeout rc=0
  timeout=$(_fm_brazil_timeout "${FM_BRAZIL_TOOL_TIMEOUT:-}" 300 FM_BRAZIL_TOOL_TIMEOUT) || return 1
  FM_BRAZIL_TOOL_OUTPUT=$(fm_run_timed "$timeout" brazil-worktree "$@" 2>&1) || rc=$?
  if fm_timed_out "$rc"; then
    FM_BRAZIL_TOOL_OUTPUT="brazil-worktree $1 timed out after ${timeout}s${FM_BRAZIL_TOOL_OUTPUT:+$'\n'$FM_BRAZIL_TOOL_OUTPUT}"
  fi
  return "$rc"
}

_fm_brazil_require_tool() {
  command -v brazil-worktree >/dev/null 2>&1 && return 0
  echo "fm-brazil-lib: brazil-worktree is not on PATH; install it with: toolbox install brazilworktreecli" >&2
  return 1
}

# _fm_brazil_shell_bounded <primary> <shell>: 0 when <shell> is exactly
# <primary>/worktrees/fm-<name>, the only shape this library creates or removes.
_fm_brazil_shell_bounded() {
  local primary=$1 shell=$2 name
  case "$primary$shell" in *'/../'* | *'/..') return 1 ;; esac
  case "$primary" in /?*) ;; *) return 1 ;; esac
  name=$(basename "$shell")
  case "$name" in fm-?*) ;; *) return 1 ;; esac
  [ "$shell" = "$primary/worktrees/$name" ]
}

# fm_brazil_build_workspace_shell <primary> <shell>: builds the task's empty
# workspace with brazil-worktree and writes .fm-primary. Refuses an existing
# path rather than reusing it, and removes what a failed create left behind.
fm_brazil_build_workspace_shell() {
  local primary=$1 shell=$2 name
  if ! fm_brazil_is_workspace "$primary"; then
    echo "fm-brazil-lib: '$primary' is not a Brazil workspace (no packageInfo or .brazil/)" >&2
    return 1
  fi
  if ! _fm_brazil_shell_bounded "$primary" "$shell"; then
    echo "fm-brazil-lib: refusing to build workspace '$shell': it is not $primary/worktrees/fm-<id>" >&2
    return 1
  fi
  name=$(basename "$shell")
  if [ -e "$shell" ] || [ -L "$shell" ]; then
    echo "fm-brazil-lib: workspace $shell already exists; refusing to reuse it. If no task owns it, remove it with: brazil-worktree remove --name $name --workspace $primary" >&2
    return 1
  fi
  _fm_brazil_require_tool || return 1
  if ! _fm_brazil_tool create --name "$name" --workspace "$primary" --empty; then
    echo "fm-brazil-lib: brazil-worktree create --name $name failed for $primary" >&2
    [ -z "$FM_BRAZIL_TOOL_OUTPUT" ] || printf '%s\n' "$FM_BRAZIL_TOOL_OUTPUT" >&2
    if [ -e "$shell" ] && ! fm_brazil_remove_workspace_shell "$primary" "$shell"; then
      echo "fm-brazil-lib: the partial workspace $shell is left behind; remove it with: brazil-worktree remove --name $name --workspace $primary" >&2
    fi
    return 1
  fi
  if [ ! -d "$shell/src" ]; then
    echo "fm-brazil-lib: brazil-worktree create reported success but $shell/src does not exist" >&2
    return 1
  fi
  printf '%s\n' "$primary" > "$shell/.fm-primary"
}

# _fm_brazil_package_worktree <dir> <primary-package>: 0 when <dir> is the root
# of a linked worktree of the repository checked out at <primary-package>.
_fm_brazil_package_worktree() {
  local dir=$1 primary_pkg=$2 top dir_real common want
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  dir_real=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  [ "$top" = "$dir_real" ] || return 1
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  want=$(git -C "$primary_pkg" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  want=$(cd "$want" 2>/dev/null && pwd -P) || return 1
  [ "$common" = "$want" ]
}

_fm_brazil_track() {  # <shell> <package>
  local list="$1/.fm-packages"
  if [ -f "$list" ] && grep -qxF -- "$2" "$list"; then
    return 0
  fi
  printf '%s\n' "$2" >> "$list"
}

# Prints each other Brazil workspace beside <primary>, or under FM_WORKPLACE
# (default ~/workplace), whose src/ holds <package>.
_fm_brazil_workspaces_holding() {  # <primary> <package>
  local primary=$1 package=$2 root ws
  for root in "$(dirname "$primary")" "${FM_WORKPLACE:-$HOME/workplace}"; do
    for ws in "$root"/*/; do
      ws=${ws%/}
      [ "$ws" != "$primary" ] || continue
      fm_brazil_is_workspace "$ws" || continue
      [ -d "$ws/src/$package" ] || continue
      printf '%s\n' "$ws"
    done
  done | awk '!seen[$0]++'
}

# fm_brazil_add_package <shell> <package> [<base-branch>]: adds <package> to the
# task workspace as a worktree of the primary's checkout, cut from a fresh
# fetch of origin/<base-branch> (default: origin's default branch), on branch
# fm-<id> with that upstream set. Records the package in .fm-packages before
# moving it, so teardown checks every package this call created. Calling it
# again for a package already added is a no-op.
fm_brazil_add_package() {
  local shell=$1 package=$2 base=${3:-} primary name dest pkg_src owners timeout rc out expected head
  case "$package" in
    '' | . | .. | *[!A-Za-z0-9._-]*)
      echo "error: package name '$package' must match [A-Za-z0-9._-]+" >&2
      return 1
      ;;
  esac
  if ! primary=$(fm_brazil_shell_primary "$shell"); then
    echo "error: $shell has no readable .fm-primary marker" >&2
    return 1
  fi
  name=$(basename "$shell")
  dest="$shell/src/$package"
  pkg_src="$primary/src/$package"

  if [ ! -d "$pkg_src" ] || ! _fm_brazil_package_worktree "$pkg_src" "$pkg_src"; then
    echo "error: package '$package' is not checked out in this task's primary workspace $primary (no git repository at $pkg_src)" >&2
    owners=$(_fm_brazil_workspaces_holding "$primary" "$package")
    if [ -n "$owners" ]; then
      printf "'%s' lives in another Brazil workspace:\n" "$package" >&2
      printf '%s\n' "$owners" | sed 's/^/  /' >&2
      echo "A task adds packages only from its own workspace, because each workspace builds against its own version set." >&2
      echo "Split cross-workspace work into one task per workspace: report needs-decision to firstmate." >&2
    fi
    echo "Never run brazil-worktree or brazil workspace commands against the primary workspace to work around this." >&2
    return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if _fm_brazil_package_worktree "$dest" "$pkg_src"; then
      _fm_brazil_track "$shell" "$package"
      echo "ok: $package already added at $dest" >&2
      return 0
    fi
    echo "error: '$dest' already exists and is not a worktree of $pkg_src; refusing to overwrite it" >&2
    return 1
  fi
  if ! git -C "$pkg_src" remote get-url origin >/dev/null 2>&1; then
    echo "error: $pkg_src has no origin remote, so '$package' cannot start from a fresh base" >&2
    return 1
  fi
  if git -C "$pkg_src" show-ref --verify --quiet "refs/heads/$name"; then
    echo "error: branch '$name' already exists in $pkg_src; brazil-worktree would reuse it and its removal deletes it. If no task owns it, inspect it and delete it by hand: git -C '$pkg_src' branch -D $name" >&2
    return 1
  fi
  _fm_brazil_require_tool || return 1
  timeout=$(_fm_brazil_timeout "${FM_BRAZIL_FETCH_TIMEOUT:-}" 60 FM_BRAZIL_FETCH_TIMEOUT) || return 1

  if [ -z "$base" ]; then
    rc=0
    out=$(fm_run_timed "$timeout" git -C "$pkg_src" remote set-head origin --auto 2>&1) || rc=$?
    base=$(git -C "$pkg_src" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    base=${base#origin/}
    if [ "$rc" -ne 0 ] || [ -z "$base" ]; then
      echo "error: could not resolve origin's default branch for $package; refusing to start the worktree from a stale base" >&2
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      echo "fix network access or Midway auth (mwinit), then retry" >&2
      return 1
    fi
  fi
  rc=0
  out=$(fm_run_timed "$timeout" git -C "$pkg_src" fetch --quiet origin \
    "+refs/heads/$base:refs/remotes/origin/$base" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      echo "error: fetching origin/$base for $package timed out after ${timeout}s; refusing to start the worktree from a stale base" >&2
    else
      echo "error: could not fetch origin/$base for $package; refusing to start the worktree from a stale base" >&2
    fi
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    echo "fix network access or Midway auth (mwinit), then retry" >&2
    return 1
  fi
  if ! expected=$(git -C "$pkg_src" rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}"); then
    echo "error: origin/$base is not a commit in $pkg_src" >&2
    return 1
  fi

  if ! _fm_brazil_tool addPackage --name "$name" --workspace "$primary" --package "$package"; then
    echo "error: brazil-worktree addPackage --name $name --package $package failed for $primary" >&2
    [ -z "$FM_BRAZIL_TOOL_OUTPUT" ] || printf '%s\n' "$FM_BRAZIL_TOOL_OUTPUT" >&2
    return 1
  fi
  # git -C walks up to any enclosing repository, so prove the tool made this
  # package's own worktree before a hard reset can reach anything else.
  if ! _fm_brazil_package_worktree "$dest" "$pkg_src"; then
    echo "error: brazil-worktree addPackage reported success but '$dest' is not a worktree of $pkg_src" >&2
    return 1
  fi
  _fm_brazil_track "$shell" "$package"
  if ! git -C "$dest" reset --hard --quiet "$expected"; then
    echo "error: could not move the new '$package' worktree to origin/$base; fix it with: git -C '$dest' reset --hard origin/$base" >&2
    return 1
  fi
  head=$(git -C "$dest" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ "$head" != "$expected" ]; then
    echo "error: the new '$package' worktree is at '${head:-unknown}', not origin/$base ($expected)" >&2
    return 1
  fi
  if ! git -C "$dest" branch --quiet --set-upstream-to="origin/$base" "$name"; then
    echo "error: could not set the upstream of '$name' in $dest; fix it with: git -C '$dest' branch -u origin/$base $name" >&2
    return 1
  fi
  echo "added: $package -> $dest (branch $name tracking origin/$base)"
}

# fm_brazil_validate_workspace_shell <shell> <worktree>: 0 when <shell> is an
# intact task workspace whose declared packages are all present and <worktree>
# is one of them. Sets FM_BRAZIL_PRIMARY and FM_BRAZIL_PACKAGE (the package
# <worktree> holds). Prints one reason and returns non-zero otherwise.
fm_brazil_validate_workspace_shell() {
  local shell=$1 worktree=$2 primary package wt_real found=
  FM_BRAZIL_PRIMARY=
  FM_BRAZIL_PACKAGE=
  if [ ! -d "$shell/src" ]; then
    echo "fm-brazil-lib: workspace shell '$shell' is missing or has no src/" >&2
    return 1
  fi
  if ! primary=$(fm_brazil_shell_primary "$shell"); then
    echo "fm-brazil-lib: workspace shell '$shell' has no readable .fm-primary marker" >&2
    return 1
  fi
  if ! fm_brazil_is_workspace "$primary" || ! _fm_brazil_shell_bounded "$primary" "$shell"; then
    echo "fm-brazil-lib: workspace shell '$shell' is not a task workspace of its recorded primary '$primary'" >&2
    return 1
  fi
  wt_real=$(cd "$worktree" 2>/dev/null && pwd -P) || wt_real=
  while IFS= read -r package; do
    if ! _fm_brazil_package_worktree "$shell/src/$package" "$primary/src/$package"; then
      echo "fm-brazil-lib: workspace shell '$shell' declares package '$package' but src/$package is not its worktree" >&2
      return 1
    fi
    if [ -n "$wt_real" ] && [ "$(cd "$shell/src/$package" && pwd -P)" = "$wt_real" ]; then
      found=$package
    fi
  done < <(fm_brazil_shell_packages "$shell")
  if [ -z "$found" ]; then
    echo "fm-brazil-lib: worktree '$worktree' is not a declared package of workspace shell '$shell'" >&2
    return 1
  fi
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_BRAZIL_PRIMARY=$primary
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_BRAZIL_PACKAGE=$found
}

# fm_brazil_remove_workspace_shell <primary> <shell>: removes the task workspace
# and its package worktrees and fm-<id> branches with `brazil-worktree remove`.
# Removes nothing outside <primary>/worktrees/fm-<id>. Returns non-zero, naming
# what survives, when the tool fails or leaves the shell behind.
fm_brazil_remove_workspace_shell() {
  local primary=$1 shell=$2 name
  if ! _fm_brazil_shell_bounded "$primary" "$shell"; then
    echo "fm-brazil-lib: refusing to remove workspace '$shell': it is not $primary/worktrees/fm-<id>" >&2
    return 1
  fi
  name=$(basename "$shell")
  _fm_brazil_require_tool || return 1
  if ! _fm_brazil_tool remove --name "$name" --workspace "$primary"; then
    # A workspace already gone leaves the tool nothing to find; the call above
    # still clears any registration it kept.
    [ -e "$shell" ] || [ -L "$shell" ] || return 0
    echo "fm-brazil-lib: brazil-worktree remove --name $name failed for $primary" >&2
    [ -z "$FM_BRAZIL_TOOL_OUTPUT" ] || printf '%s\n' "$FM_BRAZIL_TOOL_OUTPUT" >&2
    return 1
  fi
  if [ -e "$shell" ] || [ -L "$shell" ]; then
    echo "fm-brazil-lib: workspace $shell still exists after brazil-worktree remove" >&2
    return 1
  fi
}

# fm_brazil_launch_section <shell> <package> <fm-root>: the worker-facing
# section fm-spawn appends to the launch brief.
fm_brazil_launch_section() {
  local shell=$1 package=$2 fm_root=$3 primary
  primary=$(dirname "$(dirname "$shell")")
  cat <<EOF

# Brazil workspace
This task has its own Brazil workspace at \`$shell\`, built with brazil-worktree from the primary workspace \`$primary\`.
Your package worktree is \`$shell/src/$package\`.
It starts on branch \`$(basename "$shell")\` at a fresh fetch of origin, with that branch's upstream set; create your ship branch there as Setup says.
Declare every other package before you change it: \`$fm_root/bin/fm-worktree-add.sh <Package>\` fetches its origin and adds it at \`$shell/src/<Package>\`.
Only packages checked out in the primary workspace can be added; if the helper refuses one, append \`needs-decision:\` rather than working around it.
Never run \`brazil-worktree\` or \`brazil workspace\` commands against the primary workspace.
Cleanup checks every declared package for uncommitted or unlanded work.
EOF
}
