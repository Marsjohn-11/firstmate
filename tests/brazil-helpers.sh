#!/usr/bin/env bash
# tests/brazil-helpers.sh - Brazil workspace fixtures shared by the Brazil
# isolation suites (bin/fm-brazil-lib.sh owns the contract they exercise).
#
# fm_brazil_fake_tool <fakebin> [brazilcli|standalone|both] installs Brazil
# worktree stand-ins that reproduce the behavior observed with real git
# worktrees. `brazilcli` (the default) installs a `brazil` whose `worktree`
# subcommand matches brazilcli 2.0.217501.0: create makes
# <ws>/worktrees/<name> with a packageInfo but no src/ and rejects --empty, use
# adds a package, and delete refuses uncommitted or unpushed work without
# --force. `standalone` installs a `brazil` without that subcommand plus the
# brazil-worktree of brazilworktreecli 1.0.155.0: create --empty makes
# <ws>/worktrees/<name>/src, addPackage adds a package, and remove deletes
# unconditionally. `both` installs both tools. Either tool refuses a create
# name in use; its add puts branch <name> (reusing one that exists) on the
# primary's checkout and, for a package the primary lacks, rewrites the
# primary's packageInfo before failing; its delete removes every package
# worktree, branch <name>, and the workspace. Every call is appended to
# FM_FAKE_BRAZIL_LOG as the command line it was invoked with. Failure knobs:
# FM_FAKE_BRAZIL_FAIL=<subcommand> fails that subcommand,
# FM_FAKE_BRAZIL_PARTIAL=create fails after making the workspace,
# FM_FAKE_BRAZIL_BOGUS_ADD=1 reports success with a plain directory, and
# FM_FAKE_BRAZIL_KEEP=1 makes delete report success and keep the workspace.
#
# Always install one: it shadows any real `brazil` on the host PATH.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_brazil_fake_tool() {  # <fakebin> [brazilcli|standalone|both]
  local bin=$1 mode=${2:-brazilcli} cli=0
  case "$mode" in
    brazilcli | both) cli=1 ;;
    standalone) ;;
    *) echo "fm_brazil_fake_tool: unknown mode '$mode'" >&2; return 1 ;;
  esac
  cat > "$bin/.fake-brazil-worktree-core" <<'SH'
#!/usr/bin/env bash
set -u
flavor=$1
shift
if [ "$flavor" = cli ]; then
  tool='brazil worktree'
else
  tool=brazil-worktree
fi
[ -z "${FM_FAKE_BRAZIL_LOG:-}" ] || printf '%s %s\n' "$tool" "$*" >> "$FM_FAKE_BRAZIL_LOG"
op=${1:-}
[ $# -eq 0 ] || shift
case "$op" in --help | help) echo "$tool help"; exit 0 ;; esac
name= workspace= package= empty=0 force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name=$2; shift 2 ;;
    --workspace) workspace=$2; shift 2 ;;
    --package) package=$2; shift 2 ;;
    --empty) empty=1; shift ;;
    --force) force=1; shift ;;
    *) shift ;;
  esac
done
if [ "$flavor" = cli ] && [ "$empty" = 1 ]; then
  echo "Error: Unrecognized option: --empty"
  exit 85
fi
if [ "${FM_FAKE_BRAZIL_FAIL:-}" = "$op" ]; then
  echo "stub: forced $op failure"
  exit 85
fi
case "$flavor:$op" in
  cli:create | standalone:create) op=create ;;
  cli:use | standalone:addPackage) op=add ;;
  cli:delete | standalone:remove) op=delete ;;
  *) echo "stub: $tool has no $op"; exit 85 ;;
esac
wt="$workspace/worktrees/$name"
case "$op" in
  create)
    if [ -e "$wt" ]; then
      echo "Failed to create worktree: Worktree '$name' is already in use. Use a different name."
      exit 86
    fi
    mkdir -p "$wt"
    [ "$flavor" = cli ] || mkdir -p "$wt/src"
    printf 'base = {\n  worktree = true;\n};\npackages = { };\n' > "$wt/packageInfo"
    if [ "${FM_FAKE_BRAZIL_PARTIAL:-}" = create ]; then
      echo "stub: create died after making the workspace"
      exit 84
    fi
    echo "Created worktree at $wt"
    ;;
  add)
    if [ ! -d "$workspace/src/$package" ]; then
      printf 'platformOverride = mutated-by-%s;\n' "$package" >> "$workspace/packageInfo"
      echo "Failed to add package: Failed to checkout package in parent: $package"
      exit 86
    fi
    if [ "${FM_FAKE_BRAZIL_BOGUS_ADD:-}" = 1 ]; then
      mkdir -p "$wt/src/$package"
      echo "Package added"
      exit 0
    fi
    if git -C "$workspace/src/$package" show-ref --verify --quiet "refs/heads/$name"; then
      git -C "$workspace/src/$package" worktree add -q "$wt/src/$package" "$name" || exit 84
    else
      git -C "$workspace/src/$package" worktree add -q -b "$name" "$wt/src/$package" || exit 84
    fi
    echo "Package added"
    ;;
  delete)
    if [ ! -d "$wt" ]; then
      echo "Failed to delete worktree: Worktree not found: $name"
      exit 86
    fi
    if [ "$flavor" = cli ] && [ "$force" = 0 ]; then
      for dir in "$wt"/src/*/; do
        [ -d "$dir" ] || continue
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] ||
          [ -n "$(git -C "$dir" log --oneline '@{u}..HEAD' 2>/dev/null)" ]; then
          echo "Failed to delete worktree: Worktree '$name' has packages with uncommitted changes or unpushed commits: $(basename "$dir"). Use --force to delete it."
          exit 86
        fi
      done
    fi
    [ "${FM_FAKE_BRAZIL_KEEP:-}" != 1 ] || exit 0
    for dir in "$wt"/src/*/; do
      [ -d "$dir" ] || continue
      pkg=$(basename "$dir")
      git -C "$workspace/src/$pkg" worktree remove --force "${dir%/}" >/dev/null 2>&1 || true
      git -C "$workspace/src/$pkg" branch -D "$name" >/dev/null 2>&1 || true
    done
    rm -rf "$wt"
    echo "Deleted worktree $name"
    ;;
esac
SH
  chmod +x "$bin/.fake-brazil-worktree-core"
  # The single-quoted formats are the stub's own source, expanded when it runs.
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$cli" = 1 ]; then
      printf 'if [ "${1:-}" = worktree ]; then shift; exec "%s/.fake-brazil-worktree-core" cli "$@"; fi\n' "$bin"
    fi
    printf 'echo "\\"${1:-}\\" is not a valid subcommand of brazil"\nexit 1\n'
  } > "$bin/brazil"
  chmod +x "$bin/brazil"
  rm -f "$bin/brazil-worktree"
  if [ "$mode" != brazilcli ]; then
    printf '#!/usr/bin/env bash\nexec "%s/.fake-brazil-worktree-core" standalone "$@"\n' "$bin" > "$bin/brazil-worktree"
    chmod +x "$bin/brazil-worktree"
  fi
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
