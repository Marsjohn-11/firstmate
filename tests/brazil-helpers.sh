#!/usr/bin/env bash
# tests/brazil-helpers.sh - Brazil workspace fixtures shared by the Brazil
# isolation suites (bin/fm-brazil-lib.sh owns the contract they exercise).
#
# fm_brazil_fake_tool installs a brazil-worktree stand-in that reproduces the
# behavior observed on brazilworktreecli 1.0.155.0 with real git worktrees:
# create makes <ws>/worktrees/<name>/src and refuses a name in use; addPackage
# adds branch <name> (reusing one that exists) from the primary's checkout and,
# for a package the primary lacks, rewrites the primary's packageInfo before
# failing; remove deletes every package worktree, branch <name>, and the
# workspace. Every call is appended to FM_FAKE_BRAZIL_LOG when set. Failure
# knobs: FM_FAKE_BRAZIL_FAIL=<op> fails that op, FM_FAKE_BRAZIL_PARTIAL=create
# fails after making the workspace, FM_FAKE_BRAZIL_BOGUS_ADD=1 reports success
# with a plain directory, FM_FAKE_BRAZIL_KEEP=1 makes remove report success
# and keep the workspace.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_brazil_fake_tool() {  # <fakebin>
  cat > "$1/brazil-worktree" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_BRAZIL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_BRAZIL_LOG"
op=${1:-}
[ $# -eq 0 ] || shift
name= workspace= package=
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name=$2; shift 2 ;;
    --workspace) workspace=$2; shift 2 ;;
    --package) package=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "${FM_FAKE_BRAZIL_FAIL:-}" = "$op" ]; then
  echo "stub: forced $op failure"
  exit 85
fi
wt="$workspace/worktrees/$name"
case "$op" in
  create)
    if [ -e "$wt" ]; then
      echo "Failed to create worktree: Worktree '$name' is already in use. Use a different name."
      exit 85
    fi
    mkdir -p "$wt/src"
    printf 'base = {\n  worktree = true;\n};\npackages = { };\n' > "$wt/packageInfo"
    if [ "${FM_FAKE_BRAZIL_PARTIAL:-}" = create ]; then
      echo "stub: create died after making the workspace"
      exit 85
    fi
    echo "Created worktree at $wt"
    ;;
  addPackage)
    if [ ! -d "$workspace/src/$package" ]; then
      printf 'platformOverride = mutated-by-%s;\n' "$package" >> "$workspace/packageInfo"
      echo "Failed to add package: Failed to checkout package in parent: $package"
      exit 85
    fi
    if [ "${FM_FAKE_BRAZIL_BOGUS_ADD:-}" = 1 ]; then
      mkdir -p "$wt/src/$package"
      echo "Package added"
      exit 0
    fi
    if git -C "$workspace/src/$package" show-ref --verify --quiet "refs/heads/$name"; then
      git -C "$workspace/src/$package" worktree add -q "$wt/src/$package" "$name" || exit 85
    else
      git -C "$workspace/src/$package" worktree add -q -b "$name" "$wt/src/$package" || exit 85
    fi
    echo "Package added"
    ;;
  remove)
    if [ ! -d "$wt" ]; then
      echo "Failed to remove worktree: Worktree '$name' not found"
      exit 85
    fi
    [ "${FM_FAKE_BRAZIL_KEEP:-}" != 1 ] || exit 0
    for dir in "$wt"/src/*/; do
      [ -d "$dir" ] || continue
      pkg=$(basename "$dir")
      git -C "$workspace/src/$pkg" worktree remove --force "${dir%/}" >/dev/null 2>&1 || true
      git -C "$workspace/src/$pkg" branch -D "$name" >/dev/null 2>&1 || true
    done
    rm -rf "$wt"
    echo "Removed worktree $name"
    ;;
  *) exit 79 ;;
esac
SH
  chmod +x "$1/brazil-worktree"
}

# fm_brazil_make_workspace <ws> <package>...: a Brazil workspace holding one git
# checkout per package, each cloned from its own bare origin at
# <ws>.origins/<package>.git with a Config on branch mainline. Echoes the
# workspace's real path.
fm_brazil_make_workspace() {
  local ws=$1 package origin seed
  shift
  mkdir -p "$ws/src" "$ws.origins"
  printf 'base = {\n  workspace = fixture;\n  versionSet = "Fixture/mainline";\n};\npackages = { };\n' > "$ws/packageInfo"
  for package in "$@"; do
    origin="$ws.origins/$package.git"
    seed="$ws.origins/$package.seed"
    git init -q --bare -b mainline "$origin"
    git init -q -b mainline "$seed"
    printf 'package.%s = { interfaces = (1.0); };\n' "$package" > "$seed/Config"
    git -C "$seed" add Config
    git -C "$seed" -c user.name=t -c user.email=t@t commit -qm "seed $package"
    git -C "$seed" push -q "$origin" mainline
    git clone -q "$origin" "$ws/src/$package"
  done
  (cd "$ws" && pwd -P)
}

# fm_brazil_advance_origin <ws> <package> <file>: lands one commit on the
# package's origin mainline that the workspace checkout has not fetched.
# Echoes the new origin tip.
fm_brazil_advance_origin() {
  local seed="$1.origins/$2.seed"
  printf '%s\n' "$3" > "$seed/$3"
  git -C "$seed" add "$3"
  git -C "$seed" -c user.name=t -c user.email=t@t commit -qm "advance $3"
  git -C "$seed" push -q "$1.origins/$2.git" mainline
  git -C "$seed" rev-parse HEAD
}
