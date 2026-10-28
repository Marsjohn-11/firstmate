#!/usr/bin/env bash
# tests/fm-pipeline-watch.test.sh - behavior tests for bin/fm-pipeline-watch.sh.
#
# fm-pipeline-watch arms one bound state/pw-<pipeline>.check.sh per pipeline in
# config/watched-pipelines. Each reads GetPipelineDetails through the builder CLI
# and prints one line only on a health transition. The builder is a fakebin stub,
# selected through FM_PIPELINE_WATCH_BUILDER at arm time, that prints the file
# named by FAKE_BODY_FILE and then exits FAKE_RC or dies by FAKE_SIGNAL, so no
# test reaches the network. The response bodies mirror real GetPipelineDetails
# output. Every poll runs the armed check the way the watcher does, under a
# scrubbed environment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-pipeline-watch.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-pipeline-watch-tests)
PIPELINE=FreightPathPlannerService
URL="https://pipelines.amazon.com/pipelines/$PIPELINE"

# new_case <slug>: echo "<state>\n<fakebin>\n<body-file>" for a fresh case whose
# stub builder records its arguments to <fakebin>/args. The case's
# config/watched-pipelines lists PIPELINE.
new_case() {
  local dir fakebin
  dir="$TMP_ROOT/$1.$$.$RANDOM"
  mkdir -p "$dir/state" "$dir/config"
  chmod 700 "$dir/state"
  printf '# watched\n\n%s\n' "$PIPELINE" > "$dir/config/watched-pipelines"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/builder" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/args"
sleep "${FAKE_SLEEP:-0}"
[ -n "${FAKE_STDERR:-}" ] && printf '%s\n' "$FAKE_STDERR" >&2
cat "${FAKE_BODY_FILE:-/dev/null}"
[ -n "${FAKE_SIGNAL:-}" ] && kill -"$FAKE_SIGNAL" $$
exit "${FAKE_RC:-0}"
SH
  chmod +x "$fakebin/builder"
  printf '%s\n%s\n%s\n' "$dir/state" "$fakebin" "$dir/body.json"
}

# watch <state> <verb...>: run the script against the case's state and config.
watch() {
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$(dirname "$state")/config" \
    FM_ROOT_OVERRIDE="$ROOT" "$WATCH" "$@"
}

arm() {
  local state=$1 fakebin=$2
  FM_PIPELINE_WATCH_BUILDER="$fakebin/builder" watch "$state" arm 2>/dev/null
}

# poll <state> [KEY=VAL...]: run the armed shim as the watcher would.
poll() {
  local state=$1
  shift
  env -i HOME="$HOME" PATH="$BASE_PATH" "$@" bash "$state/pw-$PIPELINE.check.sh"
}

# details <tests-json> <blocked-promotions-json>: a GetPipelineDetails body.
details() {
  jq -cn --argjson tests "$1" --argjson blocked "$2" '
    {content: {data: {
      basicInfo: {name: "FreightPathPlannerService"},
      failuresSummary: {builds: [], tests: $tests, deployments: []},
      promotionSummary: {totalPromotions: 13, blockedPromotions: $blocked}}}}'
}

failed_test() {
  jq -cn --arg stage "$1" --arg step "$2" --arg url "$3" \
    '{stageName: $stage, stepName: $step, status: "FAILED", url: $url}'
}

blocked_promotion() {
  jq -cn --arg type "$1" --arg name "$2" '
    {id: 7380209, sourceTarget: {name: "Rudra/NA/OneBox/Prod", type: "ENV"},
     destinationTarget: {name: "Rudra/NA/Prod", type: "ENV"},
     promotionBlockers: [{name: $name, type: $type}]}'
}

HEALTHY=$(details '[]' '[]')
GAMMA_URL='http://carnaval.amazon.com/v1/viewSnapshot.do?name=FreightPathPlanner.NA.Gamma.Tardigrade.1726562746.Aggregate&timestamp=2026-09-24+17%3A30%3A02.883'
BETA_URL='https://tod.amazon.com/test_runs/574659549585-us-west-2-c6879718-c522-44f0-87a7-bd4b45c5a4ee-1790215952'
GAMMA_TEST=$(failed_test Gamma 'Tardigrade Wait Time NAAmazon Gamma' "$GAMMA_URL")
BETA_TEST=$(failed_test Beta 'RemoteIntegrationTest-IN' "$BETA_URL")
GAMMA_RED=$(details "[$GAMMA_TEST]" '[]')
BOTH_RED=$(details "[$GAMMA_TEST,$BETA_TEST]" '[]')

test_first_healthy_poll_is_silent() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case healthy)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  printf '%s' "$HEALTHY" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "first healthy poll should be silent, got: $out"
  [ "$(cat "$fakebin/args")" = 'GetPipelineDetails
{"pipelineName":"FreightPathPlannerService","includeAllFailures":true}' ] ||
    fail "the builder should receive GetPipelineDetails and its payload, got: $(cat "$fakebin/args")"
  pass "first healthy poll is silent"
}

test_failures_wake_only_when_new() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case failing)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  printf '%s' "$HEALTHY" > "$body"
  poll "$state" FAKE_BODY_FILE="$body" >/dev/null
  printf '%s' "$GAMMA_RED" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  assert_contains "$out" "pipeline-failing: $PIPELINE test Gamma/Tardigrade Wait Time NAAmazon Gamma $URL" \
    "a new failure should wake with its label and the pipeline url"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "the same failure set should stay silent, got: $out"
  printf '%s' "$BOTH_RED" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ "$out" = "pipeline-failing: $PIPELINE test Gamma/Tardigrade Wait Time NAAmazon Gamma; test Beta/RemoteIntegrationTest-IN $URL" ] ||
    fail "a second new failure should wake listing every current failure, got: $out"
  printf '%s' "$GAMMA_RED" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "a partial clear is not a new failure, got: $out"
  pass "failures wake once each, and a new failure on a red pipeline wakes"
}

test_build_and_deploy_failures_wake() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case build-deploy)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  jq -cn '{content: {data: {failuresSummary: {
    builds: [{stageName: "Packages", stepName: "FreightPathPlannerService; mainline", status: "FAILED",
              url: "https://build.amazon.com/7001"}],
    tests: [],
    deployments: [{stageName: "Beta", stepName: "Deploy NA Beta", status: "FAILED",
                   url: "https://pipelines.amazon.com/deployments/7002"}]},
    promotionSummary: {blockedPromotions: []}}}}' > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  assert_contains "$out" "pipeline-failing: $PIPELINE build Packages/FreightPathPlannerService; mainline; deploy Beta/Deploy NA Beta $URL" \
    "failed builds and deployments should wake with every label joined intact"
  pass "failed build and deployment steps wake"
}

test_promotion_blockers_wake_unless_time_window() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case blockers)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  details '[]' "[$(blocked_promotion TIME_WINDOW 'Retail Website US')]" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "a TIME_WINDOW-only blocker should stay silent, got: $out"
  details '[]' "[$(blocked_promotion ALARM 'Rudra.NA.Prod.PipelinePromotionGate')]" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  assert_contains "$out" "pipeline-failing: $PIPELINE blocked Rudra/NA/OneBox/Prod->Rudra/NA/Prod by Rudra.NA.Prod.PipelinePromotionGate $URL" \
    "an alarm blocker should wake naming the blocked promotion"
  pass "a promotion blocker wakes unless it is only a TIME_WINDOW"
}

test_recovery_wakes_once() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case recovery)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  printf '%s' "$GAMMA_RED" > "$body"
  poll "$state" FAKE_BODY_FILE="$body" >/dev/null
  printf '%s' "$HEALTHY" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ "$out" = "pipeline-recovered: $PIPELINE $URL" ] || fail "recovery should wake once, got: $out"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "a still-healthy pipeline should stay silent, got: $out"
  pass "recovery to healthy wakes once"
}

test_read_failures_are_stale_once_per_hour() {
  local state fakebin body out leftover
  { read -r state; read -r fakebin; read -r body; } < <(new_case stale)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  printf '%s' "$GAMMA_RED" > "$body"
  poll "$state" FAKE_BODY_FILE="$body" >/dev/null
  out=$(poll "$state" FAKE_RC=1 FAKE_STDERR='Error: Midway authentication required')
  assert_contains "$out" "pipeline-watch-stale: $PIPELINE builder read failed (rc=1): Error: Midway authentication required $URL" \
    "an empty failed read should report stale with the builder's first stderr line"
  for leftover in "$state/pw-$PIPELINE.seen.err."*; do
    assert_absent "$leftover" "a poll should remove its stderr temp file"
  done
  printf '%s' 'not json' > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "a second failed read inside the hour should stay silent, got: $out"
  printf '%s' "$GAMMA_RED" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "the red pipeline after a stale read should not re-wake, got: $out"
  out=$(poll "$state" FAKE_RC=1)
  [ -z "$out" ] || fail "a good read in between must not reopen the hourly stale window, got: $out"
  sleep 2
  printf '%s' 'not json' > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body" FM_PIPELINE_WATCH_STALE_SECS=1)
  assert_contains "$out" "pipeline-watch-stale: $PIPELINE unparsable builder output" \
    "a persisting read failure should re-emit after the interval"
  printf '%s' "$GAMMA_RED" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "a stale period must not look like recovery or a new failure, got: $out"
  pass "a failed read is stale at most once per interval and never recovered"
}

test_json_without_pipeline_data_is_stale_not_recovered() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case no-data)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  printf '%s' "$GAMMA_RED" > "$body"
  poll "$state" FAKE_BODY_FILE="$body" >/dev/null
  printf '%s' '{"content":{"data":{}}}' > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  assert_contains "$out" "pipeline-watch-stale: $PIPELINE unparsable builder output" \
    "a JSON body with no failuresSummary should be stale, not healthy"
  printf '%s' "$GAMMA_RED" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "the red pipeline after a no-data read should not re-wake, got: $out"
  pass "a JSON body without pipeline data is stale and never recovery"
}

test_signal_killed_read_is_stale_not_recovered() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case signal)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  printf '%s' "$GAMMA_RED" > "$body"
  poll "$state" FAKE_BODY_FILE="$body" >/dev/null
  printf '%s' "$HEALTHY" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body" FAKE_SIGNAL=TERM)
  assert_contains "$out" "pipeline-watch-stale: $PIPELINE builder read failed (rc=143)" \
    "a builder that prints a healthy body and then dies by SIGTERM should be stale, not recovered"
  pass "a signal-killed builder read is stale even when its body parses"
}

test_each_read_failure_mode_is_stale() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case modes)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  jq -cn '{content: {errors: ["Pipeline '"'"'X'"'"' was not found."]}}' > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body" FM_PIPELINE_WATCH_STALE_SECS=0)
  assert_contains "$out" "builder error: Pipeline 'X' was not found." "a builder error body should be stale"
  out=$(poll "$state" FM_PIPELINE_WATCH_STALE_SECS=0)
  assert_contains "$out" "builder returned no output" "a silent empty exit should say the builder returned nothing"
  printf '%s' "$HEALTHY" > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body" FAKE_SLEEP=5 FM_PIPELINE_WATCH_TIMEOUT=1 FM_PIPELINE_WATCH_STALE_SECS=0)
  assert_contains "$out" "builder read timed out after 1s" "a hung builder should be stale"
  out=$(poll "$state" FAKE_BODY_FILE="$body" FM_PIPELINE_WATCH_BUILDER="$fakebin/absent" FM_PIPELINE_WATCH_STALE_SECS=0)
  assert_contains "$out" "builder CLI not found at $fakebin/absent" "a missing builder CLI should be stale, not a crash"
  pass "builder errors, timeouts, and a missing CLI all report stale"
}

# fake_builder_mcp <path>: a stdio MCP server stand-in that answers initialize
# and one tools/call with the file named by FAKE_BODY_FILE as its text result,
# recording its arguments and the call request beside itself.
fake_builder_mcp() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$0")
printf '%s\n' "$@" > "$dir/mcp-args"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | jq -r '.id // empty')
  case "$id" in
    1) jq -cn '{jsonrpc: "2.0", id: 1, result: {protocolVersion: "2025-06-18", capabilities: {}}}' ;;
    2) printf '%s\n' "$line" > "$dir/mcp-call"
       jq -cn --rawfile body "${FAKE_BODY_FILE:-/dev/null}" \
         '{jsonrpc: "2.0", id: 2, result: {content: [{type: "text", text: $body}]}}' ;;
  esac
done
SH
  chmod +x "$1"
}

test_default_builder_is_builder_mcp_over_stdio() {
  local state fakebin body home out
  { read -r state; read -r fakebin; read -r body; } < <(new_case default-builder)
  home="$(dirname "$state")/home"
  fake_builder_mcp "$home/.toolbox/bin/builder-mcp"
  (unset FM_PIPELINE_WATCH_BUILDER; watch "$state" arm >/dev/null 2>&1) || fail "arm failed"
  assert_no_grep FM_PIPELINE_WATCH_BUILDER "$state/pw-$PIPELINE.check.sh" "an arm without an override should not pin a builder"
  printf '%s' "$GAMMA_RED" > "$body"
  out=$(env -i HOME="$home" PATH="$BASE_PATH" FAKE_BODY_FILE="$body" bash "$state/pw-$PIPELINE.check.sh")
  assert_contains "$out" "pipeline-failing: $PIPELINE test Gamma/Tardigrade Wait Time NAAmazon Gamma $URL" \
    "the default read should go through builder-mcp under HOME's toolbox"
  assert_grep 'GetPipelineDetails' "$home/.toolbox/bin/mcp-args" "builder-mcp should be limited to GetPipelineDetails"
  [ "$(jq -c '.params' "$home/.toolbox/bin/mcp-call")" = '{"name":"GetPipelineDetails","arguments":{"pipelineName":"FreightPathPlannerService","includeAllFailures":true}}' ] ||
    fail "builder-mcp should receive the GetPipelineDetails call, got: $(cat "$home/.toolbox/bin/mcp-call")"
  pass "without an override the watch calls builder-mcp's GetPipelineDetails over stdio"
}

test_build_failure_without_step_name_is_labelled_by_target() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case version-set)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  jq -cn '{content: {data: {failuresSummary: {tests: [], deployments: [], builds: [
    {targetName: "RewindApp/mainline", targetType: "VS", stageName: "VersionSet", status: "FAILED",
     description: "auto merge", url: "https://build.amazon.com/8063505301"}]},
    promotionSummary: {blockedPromotions: []}}}}' > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ "$out" = "pipeline-failing: $PIPELINE build VersionSet/RewindApp/mainline $URL" ] ||
    fail "a version-set build failure has no stepName and should be labelled by its target, got: $out"
  pass "a build failure without a step name is labelled by its target"
}

test_failures_without_url_are_keyed_by_label() {
  local state fakebin body out
  { read -r state; read -r fakebin; read -r body; } < <(new_case no-url)
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  jq -cn '{content: {data: {failuresSummary: {builds: [], deployments: [], tests: [
    {stageName: "Beta", stepName: "Integration\nTests NA", status: "FAILED"}]},
    promotionSummary: {blockedPromotions: []}}}}' > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ "$out" = "pipeline-failing: $PIPELINE test Beta/Integration Tests NA $URL" ] ||
    fail "a url-less failure should wake on one line with its name flattened, got: $out"
  jq -cn '{content: {data: {failuresSummary: {builds: [], deployments: [], tests: [
    {stageName: "Beta", stepName: "Integration\nTests NA", status: "FAILED"},
    {stageName: "Gamma", stepName: "Integration Tests EU", status: "FAILED", url: ""}]},
    promotionSummary: {blockedPromotions: []}}}}' > "$body"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  assert_contains "$out" "test Gamma/Integration Tests EU" "a second url-less failure should wake as new"
  out=$(poll "$state" FAKE_BODY_FILE="$body")
  [ -z "$out" ] || fail "the same url-less failures should stay silent, got: $out"
  pass "failures without a url are keyed by their label"
}

test_usage_errors() {
  local out status
  status=0
  out=$("$WATCH" poll 2>&1) || status=$?
  expect_code 1 "$status" "a poll without a pipeline"
  assert_contains "$out" "usage: fm-pipeline-watch.sh arm | poll <pipeline> | disarm [<pipeline>]" "a missing pipeline should print usage"
  status=0
  out=$("$WATCH" watch "$PIPELINE" 2>&1) || status=$?
  expect_code 1 "$status" "an unknown verb"
  assert_contains "$out" "usage: fm-pipeline-watch.sh" "an unknown verb should print usage"
  out=$("$WATCH" --help) || fail "--help should exit 0"
  assert_contains "$out" "config/watched-pipelines" "--help should name the pipeline list"
  pass "a missing pipeline or unknown verb exits 1 with usage"
}

test_arm_and_disarm() {
  local state fakebin body out status bad
  { read -r state; read -r fakebin; read -r body; } < <(new_case arm)
  out=$(arm "$state" "$fakebin") || fail "arm failed"
  assert_contains "$out" "armed: state/pw-$PIPELINE.check.sh watches $URL" "arm should confirm the check and url"
  assert_present "$state/pw-$PIPELINE.check.sh" "arm should write the check"
  assert_present "$state/pw-$PIPELINE.check-trust" "arm should bind the check for the watcher"
  out=$(arm "$state" "$fakebin") || fail "a repeat arm failed"
  assert_contains "$out" "armed: state/pw-$PIPELINE.check.sh" "a repeat arm should be a no-op success"
  printf '%s' "$HEALTHY" > "$body"
  poll "$state" FAKE_BODY_FILE="$body" >/dev/null
  assert_present "$state/pw-$PIPELINE.seen" "a poll should record the seen file"
  : > "$state/pw-$PIPELINE.seen.err.stray"
  out=$(watch "$state" disarm "$PIPELINE" 2>/dev/null) || fail "disarm failed"
  assert_contains "$out" "disarmed: pipeline watch for $PIPELINE" "disarm should confirm"
  assert_absent "$state/pw-$PIPELINE.check.sh" "disarm should remove the check"
  assert_absent "$state/pw-$PIPELINE.check-trust" "disarm should remove the trust binding"
  assert_absent "$state/pw-$PIPELINE.seen" "disarm should remove the seen file"
  assert_absent "$state/pw-$PIPELINE.seen.err.stray" "disarm should remove a leftover stderr temp file"
  for bad in 'bad name' '../escape' 'x;rm' 'a"b' '.hidden'; do
    status=0
    out=$(watch "$state" poll "$bad" 2>&1) || status=$?
    [ "$status" -ne 0 ] || fail "poll accepted invalid pipeline name '$bad'"
    assert_contains "$out" "must match" "rejection should explain the name format"
  done
  [ -z "$(ls "$state")" ] || fail "rejected names should leave no files, found: $(ls "$state")"
  pass "arm writes and binds the check, disarm removes it and its records, and bad names are refused"
}

test_arm_follows_the_configured_list() {
  local state fakebin body config out
  { read -r state; read -r fakebin; read -r body; } < <(new_case sync)
  config="$(dirname "$state")/config/watched-pipelines"
  printf '%s\n  Second-Pipeline  \n' "$PIPELINE" > "$config"
  arm "$state" "$fakebin" >/dev/null || fail "arm failed"
  assert_present "$state/pw-Second-Pipeline.check.sh" "every listed pipeline should be armed, trimmed of spaces"
  printf '%s\n' "$PIPELINE" > "$config"
  out=$(arm "$state" "$fakebin") || fail "re-arm failed"
  assert_contains "$out" "disarmed: pipeline watch for Second-Pipeline" "a pipeline dropped from the list should be disarmed"
  assert_absent "$state/pw-Second-Pipeline.check.sh" "the dropped pipeline's check should be gone"
  assert_present "$state/pw-$PIPELINE.check.sh" "a still-listed pipeline should stay armed"
  out=$(watch "$state" disarm) || fail "disarm all failed"
  assert_absent "$state/pw-$PIPELINE.check.sh" "disarm with no name should remove every watch"
  pass "arm follows config/watched-pipelines and disarm with no name removes every watch"
}

test_arm_refuses_a_bad_list() {
  local state fakebin body config out status
  { read -r state; read -r fakebin; read -r body; } < <(new_case bad-list)
  config="$(dirname "$state")/config/watched-pipelines"
  printf '%s\nnot/valid\n' "$PIPELINE" > "$config"
  status=0
  out=$(arm "$state" "$fakebin" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "arm accepted an invalid pipeline line"
  assert_absent "$state/pw-$PIPELINE.check.sh" "an invalid list should arm nothing"
  printf '# nothing yet\n' > "$config"
  status=0
  out=$(watch "$state" arm 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "arm accepted an empty list"
  assert_contains "$out" "lists no pipelines" "an empty list should say so"
  rm -f "$config"
  status=0
  out=$(watch "$state" arm 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "arm accepted a missing list"
  assert_contains "$out" "no pipeline list at" "a missing list should name the path"
  pass "arm refuses an invalid, empty, or missing pipeline list"
}

test_first_healthy_poll_is_silent
test_failures_wake_only_when_new
test_build_and_deploy_failures_wake
test_promotion_blockers_wake_unless_time_window
test_recovery_wakes_once
test_read_failures_are_stale_once_per_hour
test_json_without_pipeline_data_is_stale_not_recovered
test_signal_killed_read_is_stale_not_recovered
test_each_read_failure_mode_is_stale
test_default_builder_is_builder_mcp_over_stdio
test_build_failure_without_step_name_is_labelled_by_target
test_failures_without_url_are_keyed_by_label
test_usage_errors
test_arm_and_disarm
test_arm_follows_the_configured_list
test_arm_refuses_a_bad_list
