#!/usr/bin/env bash
# fm-no-mistakes-test.sh - deterministic complete-suite command for the
# no-mistakes Test step.
#
# Usage:
#   fm-no-mistakes-test.sh
#   fm-no-mistakes-test.sh --list-plan
#   fm-no-mistakes-test.sh --check-plan <path>
#   fm-no-mistakes-test.sh --required-skips <path>
#
# The execution path derives its lanes from bin/fm-test-run.sh --list-lanes:
# both portable parallel lanes, every portable-serial-<k>of<n> shard, and the
# real-herdr-gated lane.
# It writes "<lane><TAB><tests/*.test.sh path>" rows, then validates that plan
# against the runner's real --list --all discovery before executing anything.
# A discovered file in zero lanes, a file in multiple lanes, an empty lane, an
# unknown file, or a zero-test inventory fails by name.
#
# Every lane runs serially inside its own independent local clone and private
# TMPDIR and process group.
# The lanes run concurrently, matching CI's isolation boundary while keeping
# concurrency below the repository runner's 16-worker refusal.
# The current worktree diff is applied to every clone so local verification
# exercises tracked edits before they are committed.
# The assigned worker's FM_TASK_ID marker is removed only inside those
# wrapper-owned clones; their independent Git directories otherwise look like
# primary checkouts to the runner's task-placement refusal.
# An independent watchdog reaps every lane process group if this command exits
# without reaching its shell traps, so a helper cannot survive its lane owner
# and contaminate later measurements.
#
# Each lane writes runner timing JSON.
# The command refuses a missing artifact, a lane count that differs from its
# validated plan, an aggregate count that differs from discovery, or any failed
# script.
# Capability gate-skips remain distinct from both passes and assertion failures
# in FM_TEST_GATE_SUMMARY.skipped_gate. A required missing prerequisite still
# makes its lane and this gate exit non-zero. The Herdr lane requires the Herdr
# binary. Only the lane holding tests/fm-pi-primary-types.test.sh carries the Pi
# typecheck requirement, and only on a host that has npm, tsc and the Pi package;
# a host missing one records a named capability skip instead of a red lane.
#
# The --list-plan, --check-plan and --required-skips inspection modes execute no
# tests.
# --check-plan validates a supplied plan against current discovery so the
# missing-file and duplicate-file refusals can be demonstrated without
# weakening the real plan generator.
# --required-skips prints the "<lane><TAB><required skip token>" rows the run
# path would hand its lanes for a supplied plan.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/bin/fm-test-run.sh"
LANE_GUARD="$ROOT/bin/fm-test-lane-guard.py"
MODE=run
CHECK_PLAN=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-no-mistakes-test: %s\n' "$*" >&2
  exit 2
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

load_snapshot() {
  local cores loads
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo unknown)
  if [ -r /proc/loadavg ]; then
    loads=$(awk '{ print $1 "/" $2 "/" $3 }' /proc/loadavg)
  else
    loads=$(sysctl -n vm.loadavg 2>/dev/null |
      sed 's/[{}]//g; s/^[[:space:]]*//; s/[[:space:]][[:space:]]*/\//g' || echo unknown)
  fi
  printf 'cores=%s load1_5_15=%s' "$cores" "$loads"
}

selected_lanes() {
  local lane found_parallel_1=0 found_parallel_2=0 found_serial=0 found_herdr=0
  while IFS= read -r lane; do
    case "$lane" in
      portable-parallel-1)
        printf '%s\n' "$lane"
        found_parallel_1=1
        ;;
      portable-parallel-2)
        printf '%s\n' "$lane"
        found_parallel_2=1
        ;;
      portable-serial-[0-9]*of[0-9]*)
        printf '%s\n' "$lane"
        found_serial=$((found_serial + 1))
        ;;
      real-herdr-gated)
        printf '%s\n' "$lane"
        found_herdr=1
        ;;
    esac
  done < <("$RUNNER" --list-lanes)
  [ "$found_parallel_1" -eq 1 ] || die "runner did not publish portable-parallel-1"
  [ "$found_parallel_2" -eq 1 ] || die "runner did not publish portable-parallel-2"
  [ "$found_serial" -gt 0 ] || die "runner published no portable serial shards"
  [ "$found_herdr" -eq 1 ] || die "runner did not publish real-herdr-gated"
}

write_plan() { # <path>
  local out=$1 lane script count
  : >"$out"
  while IFS= read -r lane; do
    count=0
    while IFS= read -r script; do
      [ -n "$script" ] || continue
      printf '%s\t%s\n' "$lane" "$script" >>"$out"
      count=$((count + 1))
    done < <("$RUNNER" --list --lane "$lane")
    [ "$count" -gt 0 ] || die "lane '$lane' selected zero tests"
  done < <(selected_lanes)
}

validate_plan() { # <path>
  local plan=$1 tmp missing extra duplicates invalid line lane script
  [ -f "$plan" ] || die "plan not found: $plan"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-plan.XXXXXX") || return 1
  "$RUNNER" --list --all | LC_ALL=C sort -u >"$tmp/discovered"
  if [ ! -s "$tmp/discovered" ]; then
    rm -rf "$tmp"
    die "test discovery returned zero tests"
  fi

  : >"$tmp/planned"
  invalid=0
  while IFS=$'\t' read -r lane script extra_field; do
    line=${lane}${script}${extra_field:-}
    [ -n "$line" ] || continue
    if [ -z "$lane" ] || [ -z "$script" ] || [ -n "${extra_field:-}" ]; then
      printf 'fm-no-mistakes-test: invalid plan row: %s\\t%s\\t%s\n' \
        "$lane" "$script" "${extra_field:-}" >&2
      invalid=1
      continue
    fi
    printf '%s\n' "$script" >>"$tmp/planned"
  done <"$plan"
  if [ "$invalid" -ne 0 ]; then
    rm -rf "$tmp"
    return 1
  fi

  LC_ALL=C sort "$tmp/planned" >"$tmp/planned.sorted"
  LC_ALL=C uniq -d "$tmp/planned.sorted" >"$tmp/duplicates"
  LC_ALL=C sort -u "$tmp/planned.sorted" >"$tmp/planned.unique"
  duplicates=$(cat "$tmp/duplicates")
  missing=$(comm -23 "$tmp/discovered" "$tmp/planned.unique" || true)
  extra=$(comm -13 "$tmp/discovered" "$tmp/planned.unique" || true)
  if [ -n "$duplicates" ]; then
    printf 'fm-no-mistakes-test: files assigned to multiple lanes:\n%s\n' "$duplicates" >&2
  fi
  if [ -n "$missing" ]; then
    printf 'fm-no-mistakes-test: discovered files assigned to zero lanes:\n%s\n' "$missing" >&2
  fi
  if [ -n "$extra" ]; then
    printf 'fm-no-mistakes-test: planned files absent from discovery:\n%s\n' "$extra" >&2
  fi
  if [ -n "$duplicates" ] || [ -n "$missing" ] || [ -n "$extra" ]; then
    rm -rf "$tmp"
    return 1
  fi
  printf 'FM_TEST_PLAN ok total=%s lanes=%s\n' \
    "$(wc -l <"$tmp/discovered" | tr -d ' ')" \
    "$(cut -f1 "$plan" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  rm -rf "$tmp"
}

PI_TYPES_TEST=tests/fm-pi-primary-types.test.sh
PI_SKIP_TOKEN='Pi extension typecheck prerequisite not found'
HERDR_SKIP_TOKEN='herdr not found'

# The Pi typecheck requirement only applies where every prerequisite the test
# names is present, which is what CI installs. A host missing npm, tsc or the Pi
# package skips by name instead.
pi_prerequisites_available() {
  local dir
  command -v npm >/dev/null 2>&1 || return 1
  command -v tsc >/dev/null 2>&1 || return 1
  dir=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
  [ -f "$dir/package.json" ]
}

pi_required_lane() { # <plan>
  local lane
  lane=$(awk -F '\t' -v t="$PI_TYPES_TEST" '$2 == t { print $1; exit }' "$1")
  [ -n "$lane" ] || return 0
  pi_prerequisites_available || return 0
  printf '%s\n' "$lane"
}

required_skip_for_lane() { # <lane> <pi-required-lane>
  local lane=$1 pi_lane=$2
  if [ "$lane" = real-herdr-gated ]; then
    printf '%s\n' "$HERDR_SKIP_TOKEN"
  elif [ -n "$pi_lane" ] && [ "$lane" = "$pi_lane" ]; then
    printf '%s\n' "$PI_SKIP_TOKEN"
  fi
}

run_lane_process() { # <lane-dir> <patch> <head-sha> <lane> <planned-count> <required-skip>
  local lane_dir=$1 patch=$2 head_sha=$3 lane=$4 lane_count=$5 required_skip=$6
  local checkout log json prep_rc rc
  local -a lane_args
  set +e
  checkout="$lane_dir/repo"
  log="$lane_dir/output.log"
  json="$lane_dir/timing.json"
  {
    printf 'FM_TEST_LANE_BEGIN lane=%s planned=%s %s\n' "$lane" "$lane_count" "$(load_snapshot)"
    git clone --quiet --no-hardlinks "$ROOT" "$checkout" &&
      git -C "$checkout" checkout --quiet --detach "$head_sha" &&
      if [ -s "$patch" ]; then git -C "$checkout" apply --binary "$patch"; else :; fi
    prep_rc=$?
    if [ "$prep_rc" -eq 0 ]; then
      lane_args=(--lane "$lane" --per-script-timeout-secs 900 --json "$json")
      if [ -n "$required_skip" ]; then
        lane_args+=(--fail-on-gate-skip "$required_skip")
      fi
      (
        cd "$checkout" || exit 1
        env -u FM_TASK_ID -u FM_HOME -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
          -u FM_PROJECTS_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_BACKEND \
          TMPDIR="$lane_dir/tmp" TMP="$lane_dir/tmp" \
          bash bin/fm-test-run.sh "${lane_args[@]}"
      )
      rc=$?
    else
      rc=$prep_rc
    fi
    printf 'FM_TEST_LANE_END lane=%s exit=%s %s\n' "$lane" "$rc" "$(load_snapshot)"
  } >"$log" 2>&1
  printf '%s\n' "$rc" >"$lane_dir/exit"
  exit 0
}

if [ "${1:-}" = "--run-lane" ]; then
  [ "$#" -eq 7 ] || die "--run-lane requires six internal arguments"
  run_lane_process "$2" "$3" "$4" "$5" "$6" "$7"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list-plan)
      [ "$MODE" = run ] || die "choose only one inspection mode"
      MODE=list
      shift
      ;;
    --check-plan)
      [ "$MODE" = run ] || die "choose only one inspection mode"
      [ "$#" -gt 1 ] || die "--check-plan requires a path"
      MODE=check
      CHECK_PLAN=$2
      shift 2
      ;;
    --required-skips)
      [ "$MODE" = run ] || die "choose only one inspection mode"
      [ "$#" -gt 1 ] || die "--required-skips requires a path"
      MODE=skips
      CHECK_PLAN=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [ "$MODE" = list ]; then
  plan_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-nm-plan.XXXXXX")
  trap 'rm -f "$plan_tmp"' EXIT
  write_plan "$plan_tmp"
  validate_plan "$plan_tmp" >/dev/null
  cat "$plan_tmp"
  exit 0
fi

if [ "$MODE" = check ]; then
  validate_plan "$CHECK_PLAN"
  exit $?
fi

if [ "$MODE" = skips ]; then
  [ -f "$CHECK_PLAN" ] || die "plan not found: $CHECK_PLAN"
  pi_lane=$(pi_required_lane "$CHECK_PLAN")
  while IFS= read -r lane; do
    [ -n "$lane" ] || continue
    token=$(required_skip_for_lane "$lane" "$pi_lane")
    [ -n "$token" ] || continue
    printf '%s\t%s\n' "$lane" "$token"
  done < <(cut -f1 "$CHECK_PLAN" | LC_ALL=C sort -u)
  exit 0
fi

command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -x "$RUNNER" ] || die "test runner is not executable: $RUNNER"
[ -x "$LANE_GUARD" ] || die "lane guard is not executable: $LANE_GUARD"

RUN_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-test.XXXXXX") || exit 1
PLAN="$RUN_ROOT/plan.tsv"
PATCH="$RUN_ROOT/worktree.patch"
AGGREGATE="$RUN_ROOT/aggregate.json"
GROUPS_FILE="$RUN_ROOT/lane-groups"
RUN_STARTED_MS=$(now_ms)
LANE_PIDS=()
WATCHDOG_PID=
CLEANED=0

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=
  fi
  python3 "$LANE_GUARD" reap "$GROUPS_FILE" 2>/dev/null || true
  for pid in "${LANE_PIDS[@]+"${LANE_PIDS[@]}"}"; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$RUN_ROOT"
}

# shellcheck disable=SC2329 # Invoked by the signal traps below.
interrupted() {
  trap - HUP INT TERM
  cleanup
  exit 130
}

trap cleanup EXIT
trap interrupted HUP INT TERM

write_plan "$PLAN"
validate_plan "$PLAN"
"$RUNNER" --check-coverage
git -C "$ROOT" diff --binary HEAD -- . >"$PATCH"
HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD)
: >"$GROUPS_FILE"
PARENT_START=$(ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
[ -n "$PARENT_START" ] || die "could not read parent process identity"
python3 "$LANE_GUARD" watch "$$" "$PARENT_START" "$GROUPS_FILE" &
WATCHDOG_PID=$!

LANES=()
while IFS= read -r lane; do
  [ -n "$lane" ] || continue
  LANES+=("$lane")
done < <(cut -f1 "$PLAN" | LC_ALL=C sort -u)
[ "${#LANES[@]}" -gt 0 ] || die "validated plan contains zero lanes"

printf 'FM_TEST_GATE_BEGIN commit=%s lanes=%s tests=%s %s\n' \
  "$HEAD_SHA" "${#LANES[@]}" "$(wc -l <"$PLAN" | tr -d ' ')" "$(load_snapshot)"

PI_REQUIRED_LANE=$(pi_required_lane "$PLAN")

lane_index=0
for lane in "${LANES[@]}"; do
  lane_index=$((lane_index + 1))
  lane_dir="$RUN_ROOT/lane-$lane_index"
  lane_count=$(awk -F '\t' -v lane="$lane" '$1 == lane { n++ } END { print n + 0 }' "$PLAN")
  required_skip=$(required_skip_for_lane "$lane" "$PI_REQUIRED_LANE")
  mkdir -p "$lane_dir/tmp"
  python3 "$LANE_GUARD" run "$0" --run-lane \
    "$lane_dir" "$PATCH" "$HEAD_SHA" "$lane" "$lane_count" "$required_skip" &
  lane_pid=$!
  LANE_PIDS+=("$lane_pid")
  printf '%s\n' "$lane_pid" >>"$GROUPS_FILE"
done

last_progress=0
while :; do
  completed=0
  for lane_index in "${!LANES[@]}"; do
    lane_dir="$RUN_ROOT/lane-$((lane_index + 1))"
    [ -f "$lane_dir/exit" ] && completed=$((completed + 1))
  done
  [ "$completed" -lt "${#LANES[@]}" ] || break
  elapsed=$((($(now_ms) - RUN_STARTED_MS) / 1000))
  if [ "$elapsed" -ge $((last_progress + 30)) ]; then
    printf 'FM_TEST_GATE_PROGRESS completed=%s/%s elapsed_seconds=%s %s\n' \
      "$completed" "${#LANES[@]}" "$elapsed" "$(load_snapshot)"
    last_progress=$elapsed
  fi
  sleep 2
done

for lane_index in "${!LANES[@]}"; do
  wait "${LANE_PIDS[$lane_index]}" || true
done
LANE_PIDS=()

lane_failure=0
JSON_INPUTS=()
for lane_index in "${!LANES[@]}"; do
  lane=${LANES[$lane_index]}
  lane_dir="$RUN_ROOT/lane-$((lane_index + 1))"
  cat "$lane_dir/output.log"
  rc=$(cat "$lane_dir/exit" 2>/dev/null || echo 1)
  [ "$rc" -eq 0 ] || lane_failure=1
  if [ ! -f "$lane_dir/timing.json" ]; then
    printf 'fm-no-mistakes-test: lane %s produced no timing artifact\n' "$lane" >&2
    lane_failure=1
    continue
  fi
  JSON_INPUTS+=("$lane_dir/timing.json")
done

[ "${#JSON_INPUTS[@]}" -eq "${#LANES[@]}" ] || lane_failure=1
if [ "${#JSON_INPUTS[@]}" -gt 0 ]; then
  "$RUNNER" --aggregate-json "$AGGREGATE" "${JSON_INPUTS[@]}"
else
  printf 'fm-no-mistakes-test: no lane timing artifacts were produced\n' >&2
  exit 1
fi

set +e
python3 - "$AGGREGATE" "$PLAN" "$RUN_STARTED_MS" <<'PY'
import collections
import json
import sys
import time

aggregate_path, plan_path, started_ms = sys.argv[1:]
doc = json.load(open(aggregate_path, encoding="utf-8"))
plan = []
with open(plan_path, encoding="utf-8") as handle:
    for line in handle:
        lane, path = line.rstrip("\n").split("\t", 1)
        plan.append((lane, path))

rows = doc.get("scripts") or []
summary = doc.get("summary") or {}
expected_paths = sorted(path for _, path in plan)
actual_paths = sorted(str(row.get("path") or "") for row in rows)
problems = []
if actual_paths != expected_paths:
    expected = collections.Counter(expected_paths)
    actual = collections.Counter(actual_paths)
    for path in sorted((expected - actual).elements()):
        problems.append(f"missing aggregate result: {path}")
    for path in sorted((actual - expected).elements()):
        problems.append(f"unexpected or duplicate aggregate result: {path}")

total = int(summary.get("total") or 0)
failed = int(summary.get("failed") or 0)
skipped = int(summary.get("skipped_gate") or 0)
lanes = int(summary.get("lanes") or 0)
if total != len(plan):
    problems.append(f"aggregate total {total} differs from validated plan {len(plan)}")
if lanes != len(set(lane for lane, _ in plan)):
    problems.append(f"aggregate lane count {lanes} differs from validated plan")
if total <= 0:
    problems.append("aggregate reported zero tests")
passed = total - failed - skipped
if passed < 0:
    problems.append("failed plus skipped exceeds total")
duration_ms = max(0, int(time.time() * 1000) - int(started_ms))
print(
    "FM_TEST_GATE_SUMMARY "
    f"lanes={lanes} total={total} passed={passed} failed={failed} "
    f"skipped_gate={skipped} duration_ms={duration_ms}"
)
for problem in problems:
    print(f"fm-no-mistakes-test: {problem}", file=sys.stderr)
if problems or failed:
    raise SystemExit(1)
PY
summary_rc=$?
set -e

if [ "$lane_failure" -ne 0 ] || [ "$summary_rc" -ne 0 ]; then
  exit 1
fi
exit 0
