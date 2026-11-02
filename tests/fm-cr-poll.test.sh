#!/usr/bin/env bash
# Behavior tests for bin/fm-cr-poll.sh, run through the trusted shim that
# bin/fm-cr-check.sh arms.
#
# mcurl is a fakebin shim driven by env vars and builder-mcp is a stub stdio
# server, so these stay hermetic; jq is the real tool. Each poll runs the armed
# state/<id>.check.sh in a fresh env, so sidecar dedupe is checked across polls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CR_CHECK="$ROOT/bin/fm-cr-check.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-cr-poll-tests)
# A no-op guard keeps the real repo's supervision banners out of arming.
GUARD_ROOT="$TMP_ROOT/root"
mkdir -p "$GUARD_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GUARD_ROOT/bin/fm-guard.sh"
chmod +x "$GUARD_ROOT/bin/fm-guard.sh"

# make_fake_mcurl <dir>: install a fakebin/mcurl that returns canned bodies and
# exit codes keyed off the URL ending. The check script calls three URL shapes
# (.../revisions, .../revisions/<rev>.json, and - for the destination-branch
# guard - .../snapshots/<id>.json), so one env var pair per kind is all that is
# needed:
#   FAKE_REVISIONS_RC / FAKE_REVISIONS_BODY     -> .../revisions
#   FAKE_REVISION_RC  / FAKE_REVISION_BODY      -> .../revisions/<n>.json
#   FAKE_REVISION_<n>_RC / FAKE_REVISION_<n>_BODY -> .../revisions/<n>.json only
#   FAKE_SNAPSHOT_RC  / FAKE_SNAPSHOT_BODY      -> .../snapshots/<id>.json
# RC defaults to 0; an empty BODY emits no stdout.
#
# The shim models two real curl behaviors the credential-path classifier depends
# on, because a shim that ignored them would make every fetch look like a
# transport failure and silently mask what the poll actually does:
#   -w <fmt>  expands %{http_code}, appended after the body. FAKE_*_HTTP_CODE
#             sets it (default 200, or 000 when RC is non-zero, matching curl on
#             a connection failure).
#   -f/-fsS   the fail flags: on an HTTP error the body is DISCARDED and curl
#             exits 22. The poll's probe deliberately fetches WITHOUT -f so it
#             can read the 403 body and tell an AEA posture page apart from a
#             plain auth rejection, so the shim has to honor both modes.
make_fake_mcurl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/mcurl" <<'SH'
#!/usr/bin/env bash
# Explicit consumption of value-taking flags so a future caller can pass the
# URL anywhere in the argv (not just last) without the shim silently matching
# the wrong URL pattern. Matches the fm-x-mode.test.sh reference shim.
url=; wfmt=; failflag=0
while [ $# -gt 0 ]; do
  case "$1" in
    -w) wfmt=$2; shift 2 ;;
    --max-time|-m|-o|-X|--data|-H) shift 2 ;;
    -f|--fail|-fsS|-sS|-fs) case "$1" in *f*) failflag=1 ;; esac; shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
body=; rc=0; code=
case "$url" in
  */revisions)        body=${FAKE_REVISIONS_BODY:-}; rc=${FAKE_REVISIONS_RC:-0}; code=${FAKE_REVISIONS_HTTP_CODE:-} ;;
  */snapshots/*.json) body=${FAKE_SNAPSHOT_BODY:-};  rc=${FAKE_SNAPSHOT_RC:-0};  code=${FAKE_SNAPSHOT_HTTP_CODE:-} ;;
  */revisions/*.json)
    # FAKE_REVISION_<n>_BODY serves revision <n> alone; otherwise every
    # revision gets FAKE_REVISION_BODY.
    n=${url##*/revisions/}; n=${n%.json}; var="FAKE_REVISION_${n}_BODY"; rcvar="FAKE_REVISION_${n}_RC"
    body=${!var:-${FAKE_REVISION_BODY:-}}; rc=${!rcvar:-${FAKE_REVISION_RC:-0}}; code=${FAKE_REVISION_HTTP_CODE:-} ;;
  *) exit 0 ;;
esac
if [ -z "$code" ]; then
  if [ "$rc" -ne 0 ]; then code=000; else code=200; fi
fi
# curl -f: HTTP errors discard the body and exit 22.
if [ "$failflag" = 1 ] && [ "$code" != 000 ] && [ "${code#2}" = "$code" ]; then
  exit 22
fi
[ "$rc" -ne 0 ] && exit "$rc"
printf '%s' "$body"
# Expand -w the way curl does: %{http_code} is substituted, and the format's
# escapes (\n) are interpreted, hence printf '%b' on the format string.
[ -n "$wfmt" ] && printf '%b' "${wfmt//'%{http_code}'/$code}"
exit 0
SH
  chmod +x "$fakebin/mcurl"
  printf '%s\n' "$fakebin"
}

# revisions_json <rev>: a minimum-viable revisions list with one non-PENDING
# entry whose revision number is <rev>. Matches the jq selector in the check.
revisions_json() {
  local rev=$1
  printf '[{"review_revision_summary":{"status":"PUBLISHED","id":{"review_revision_id":{"revision":%s}}}}]' "$rev"
}

# revision_json <status> <comment-ids-space-separated>: a revision body whose
# .revision.cr_revision.status = <status> and whose unresolved-USER-comments
# match the given ids. Each comment has fixed=false, author.entity_id.type=USER,
# and parent=null, so all of them survive the check's filter.
#
# The comment id lives at .location.comment_location.post, which is where real
# CRUX puts it. This fixture previously used a top-level `.id`, a field CRUX does
# not emit, and the poll's selector matched that same non-existent field - so the
# suite passed green while the real poll reported every CR as having zero
# unresolved comments. Keeping the fixture faithful to the service is what makes
# these tests able to catch that class of bug at all.
revision_json() {
  local status=$1 ids=$2 first=1 c id
  c=$(printf '{"status":"%s","comments":[' "$status")
  for id in $ids; do
    if [ "$first" -eq 1 ]; then first=0; else c="$c,"; fi
    c=$(printf '%s{"cr_comment":{"location":{"comment_location":{"post":"%s","location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"USER"}}}}' "$c" "$id")
  done
  c="$c]}"
  printf '{"revision":{"cr_revision":%s}}' "$c"
}

# revision_json_with_snapshot <status> <snapshot-id> [comment-ids...]: like
# revision_json but also carries a WSNAP diff_source pointing at <snapshot-id>,
# so the destination-branch guard can resolve the snapshot. This is what a real
# CR revision looks like; the plain revision_json (no diff_source) exercises the
# guard's silent can't-assess path.
revision_json_with_snapshot() {
  local status=$1 snap_id=$2 ids=$3 base rev
  base=$(revision_json "$status" "$ids")
  # Splice diff_source into .revision.cr_revision using jq so quoting stays sane.
  printf '%s' "$base" | jq -c --arg id "$snap_id" \
    '.revision.cr_revision.diff_source = {"diff_source":{"type":"WSNAP","id":$id}}'
}

# snapshot_json <pkg1>:<dest1> [<pkg2>:<dest2> ...]: a snapshot body with one
# content entry per package. A dest of "-" means the package has NO destination
# branch (empty gitfarm_branch) - the unmergeable case. Any other value is the
# gitfarm_branch (destination). local_branch is always a fixed fm/ source branch.
snapshot_json() {
  local spec content='[]' pkg dest entry
  for spec in "$@"; do
    pkg=${spec%%:*}
    dest=${spec#*:}
    [ "$dest" = "-" ] && dest=""
    entry=$(jq -cn --arg pkg "$pkg" --arg dest "$dest" \
      '{content:{package_name:$pkg, head_type:"branch", branches:[{branch:{local_branch:"fm/task-src", gitfarm_branch:$dest}}]}}')
    content=$(printf '%s\n%s\n' "$content" "$entry" | jq -sc '.[0] + [.[1]]')
  done
  jq -cn --argjson content "$content" '{snapshot:{content:$content}}'
}

# run_check <state> <id> <fakebin> [KEY=VAL...]: run the armed shim in a fresh
# env with the fake mcurl's knobs. FM_CR_FALLBACK_BIN defaults to a missing
# path, so the fallback reports itself unavailable unless a test passes a stub.
run_check() {
  local state=$1 id=$2 fakebin=$3
  shift 3
  env -i HOME="$HOME" PATH="$fakebin:$BASE_PATH" \
    FM_CR_FALLBACK_BIN="$state/no-such-builder-mcp" FM_CR_FALLBACK_TIMEOUT=60 "$@" \
    bash "$state/$id.check.sh"
}

# arm <state> <id> <CR-<digits>>: record and arm the review for a task whose
# metadata exists.
arm() {
  local state=$1 id=$2 cr=$3
  [ -f "$state/$id.meta" ] || fm_write_meta "$state/$id.meta" "window=firstmate:fm-$id" "mode=direct-PR"
  FM_ROOT_OVERRIDE="$GUARD_ROOT" FM_HOME="$(dirname "$state")" FM_STATE_OVERRIDE="$state" \
    "$CR_CHECK" "$id" "https://code.amazon.com/reviews/$cr"
}

# new_case <slug>: a fresh state dir and fake-mcurl fakebin, one per line.
new_case() {
  local slug=$1 dir state fakebin
  dir="$TMP_ROOT/$slug.$$.$RANDOM"
  mkdir -p "$dir/state"
  state="$dir/state"
  fakebin=$(make_fake_mcurl "$dir")
  printf '%s\n%s\n' "$state" "$fakebin"
}

test_check_ignores_a_sidecar_another_cr_wrote() {
  # A poll for an earlier CR can write its sidecar after a new CR is armed, and
  # that state must not dedupe the new CR's wakes.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case sidecar-other-cr)
  arm "$state" task CR-2222222 >/dev/null || fail "arming failed"
  printf 'cr=https://code.amazon.com/reviews/CR-1111111\nstate=shipped\n' > "$state/task.cr-seen"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json SHIPPED "")")
  [ "$out" = "cr-shipped" ] || fail "another CR's shipped sidecar must not silence this CR's cr-shipped, got: '$out'"
  assert_grep 'cr=https://code.amazon.com/reviews/CR-2222222' "$state/task.cr-seen" "the poll should rewrite the sidecar for its own CR"
  pass "the poll ignores a sidecar another CR wrote"
}

test_check_sidecar_names_its_cr() {
  local state fakebin
  { read -r state; read -r fakebin; } < <(new_case sidecar-names-cr)
  arm "$state" task CR-4444444 >/dev/null || fail "arming failed"
  run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json SHIPPED "")" >/dev/null
  assert_grep 'cr=https://code.amazon.com/reviews/CR-4444444' "$state/task.cr-seen" "the sidecar should name the CR it describes"
  assert_grep 'state=shipped' "$state/task.cr-seen" "the sidecar should still record the state"
  pass "the poll's sidecar names the CR it describes"
}

# ---------------------------------------------------------------------------
# Generated check.sh behavior - terminal states

test_check_emits_cr_shipped_on_shipped_or_merged_and_dedupes() {
  local state fakebin out s
  for s in SHIPPED MERGED; do
    { read -r state; read -r fakebin; } < <(new_case "shipped-$s")
    arm "$state" task CR-5555555 >/dev/null || fail "arm failed"
    # First poll: shipped landed -> one cr-shipped line + sidecar state=shipped.
    out=$(run_check "$state" task "$fakebin" \
      FAKE_REVISIONS_BODY="$(revisions_json 1)" \
      FAKE_REVISION_BODY="$(revision_json "$s" "")")
    [ "$out" = "cr-shipped" ] || fail "[$s] first poll should print cr-shipped, got: '$out'"
    assert_grep "state=shipped" "$state/task.cr-seen" "[$s] sidecar should record state=shipped"
    # Second poll: same body, must be silent (dedupe).
    out=$(run_check "$state" task "$fakebin" \
      FAKE_REVISIONS_BODY="$(revisions_json 1)" \
      FAKE_REVISION_BODY="$(revision_json "$s" "")")
    [ -z "$out" ] || fail "[$s] second poll should be silent after dedupe, got: '$out'"
  done
  pass "shipped/merged emit cr-shipped exactly once"
}

test_check_emits_cr_abandoned_on_terminal_negative_states_and_dedupes() {
  local state fakebin out s
  for s in ABANDONED CLOSED WITHDRAWN; do
    { read -r state; read -r fakebin; } < <(new_case "abandoned-$s")
    arm "$state" task CR-6666666 >/dev/null || fail "arm failed"
    out=$(run_check "$state" task "$fakebin" \
      FAKE_REVISIONS_BODY="$(revisions_json 1)" \
      FAKE_REVISION_BODY="$(revision_json "$s" "")")
    [ "$out" = "cr-abandoned" ] || fail "[$s] first poll should print cr-abandoned, got: '$out'"
    assert_grep "state=abandoned" "$state/task.cr-seen" "[$s] sidecar should record state=abandoned"
    out=$(run_check "$state" task "$fakebin" \
      FAKE_REVISIONS_BODY="$(revisions_json 1)" \
      FAKE_REVISION_BODY="$(revision_json "$s" "")")
    [ -z "$out" ] || fail "[$s] second poll should be silent after dedupe, got: '$out'"
  done
  pass "abandoned/closed/withdrawn emit cr-abandoned exactly once"
}

# ---------------------------------------------------------------------------
# Generated check.sh behavior - in-review (set membership, not count)

test_check_in_review_emits_needs_revision_on_first_unresolved_comments() {
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case in-review-first)
  arm "$state" task CR-7777777 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "c1 c2")")
  [ "$out" = "cr-needs-revision: 2 new" ] || fail "first in-review poll should print 'cr-needs-revision: 2 new', got: '$out'"
  assert_grep "state=in-review" "$state/task.cr-seen" "sidecar should record state=in-review"
  # Comments are sorted in the sidecar: c1 c2.
  assert_grep "comments=c1 c2" "$state/task.cr-seen" "sidecar should record the sorted comment set"
  pass "in-review with new unresolved comments wakes firstmate with the new count"
}

test_check_in_review_handles_all_status_synonyms() {
  # The script's in-review case arm matches five status values:
  # PUBLISHED|REVIEW_OUTSTANDING|REVIEW_COMPLETED|OPEN|IN_REVIEW. The logic is
  # identical across all five, but a pinning test against each guards the case
  # pattern from accidental edits (typo, missing |).
  local state fakebin out s
  for s in PUBLISHED REVIEW_OUTSTANDING REVIEW_COMPLETED OPEN IN_REVIEW; do
    { read -r state; read -r fakebin; } < <(new_case "in-review-$s")
    arm "$state" task CR-7777790 >/dev/null || fail "[$s] arm failed"
    out=$(run_check "$state" task "$fakebin" \
      FAKE_REVISIONS_BODY="$(revisions_json 1)" \
      FAKE_REVISION_BODY="$(revision_json "$s" "c1")")
    [ "$out" = "cr-needs-revision: 1 new" ] \
      || fail "[$s] should enter the in-review arm and wake, got: '$out'"
    assert_grep "state=in-review" "$state/task.cr-seen" "[$s] sidecar should record state=in-review"
  done
  pass "all five in-review status synonyms enter the comment-tracking arm"
}

test_check_in_review_same_set_is_silent() {
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case in-review-same)
  arm "$state" task CR-7777778 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "a b c")")
  [ "$out" = "cr-needs-revision: 3 new" ] || fail "expected first wake, got: '$out'"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "a b c")")
  [ -z "$out" ] || fail "same comment set should be silent, got: '$out'"
  pass "in-review repeats with identical comment set are silent"
}

test_check_in_review_set_membership_catches_net_zero_churn() {
  # Reviewer fixes one comment and opens another in the same poll window: count
  # is unchanged but the SET membership gained a new id. Must still wake.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case in-review-net-zero)
  arm "$state" task CR-7777779 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "c1 c2 c3")")
  [ "$out" = "cr-needs-revision: 3 new" ] || fail "expected first wake, got: '$out'"
  # Same count (3), but c1 resolved and c4 added.
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "c2 c3 c4")")
  [ "$out" = "cr-needs-revision: 1 new" ] || fail "net-zero set churn should wake with 1 new, got: '$out'"
  assert_grep "comments=c2 c3 c4" "$state/task.cr-seen" "sidecar should record the new set"
  pass "in-review wakes on set-membership change even when count is unchanged"
}

test_check_in_review_shrink_only_no_wake() {
  # A reviewer resolves a comment without opening any new ones. No new IDs in
  # the set, so the script records the new state but emits no wake.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case in-review-shrink)
  arm "$state" task CR-7777780 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "c1 c2")")
  [ "$out" = "cr-needs-revision: 2 new" ] || fail "expected first wake, got: '$out'"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "c1")")
  [ -z "$out" ] || fail "shrink-only should be silent, got: '$out'"
  assert_grep "comments=c1" "$state/task.cr-seen" "sidecar should still reflect the new (shrunken) set"
  pass "in-review wakes only when a new unresolved id appears"
}

test_check_in_review_ignores_resolved_and_replies_and_unknown_author_types() {
  # The check filters out comments where fixed=true, parent != null (replies),
  # or the author type is neither USER nor AAA. A revision JSON full of those
  # plus one human top-level unresolved must produce exactly one new id.
  local state fakebin out body
  { read -r state; read -r fakebin; } < <(new_case in-review-filters)
  arm "$state" task CR-7777781 >/dev/null || fail "arm failed"
  body=$(cat <<'JSON'
{"revision":{"cr_revision":{"status":"IN_REVIEW","comments":[
  {"cr_comment":{"location":{"comment_location":{"post":"c-real","location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"USER"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":"c-fixed","location":"TOP"}},"fixed":true,"parent":null,"author":{"entity_id":{"type":"USER"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":"c-reply","location":"TOP"}},"fixed":false,"parent":"c-real","author":{"entity_id":{"type":"USER"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":"c-bot","location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"SERVICE"}}}}
]}}}
JSON
)
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$body")
  [ "$out" = "cr-needs-revision: 1 new" ] || fail "expected exactly 1 new (only c-real qualifies), got: '$out'"
  assert_grep "comments=c-real" "$state/task.cr-seen" "sidecar should record only the qualifying comment"
  assert_no_grep "c-fixed" "$state/task.cr-seen" "fixed comments must be filtered out"
  assert_no_grep "c-reply" "$state/task.cr-seen" "reply comments must be filtered out"
  assert_no_grep "c-bot" "$state/task.cr-seen" "an author type other than USER or AAA must be filtered out"
  pass "in-review comment set excludes fixed, replies, and unknown author types"
}

test_check_counts_unresolved_aaa_review_comment_and_drops_status_bots() {
  # Real CRUX posts every service principal as author type AAA. AutoSDE and
  # KrakenReview post review findings, so they count exactly like a USER comment.
  # The status bots on the shared noise list must not count.
  local state fakebin out body
  { read -r state; read -r fakebin; } < <(new_case in-review-aaa)
  arm "$state" task CR-7777782 >/dev/null || fail "arm failed"
  body=$(cat <<'JSON'
{"revision":{"cr_revision":{"status":"PUBLISHED","comments":[
  {"cr_comment":{"location":{"comment_location":{"post":23,"location":"v4:PkgA:src/a.sh::100::100:"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"AutoSDE"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":24,"location":"v4:PkgA:src/b.ts::80::80:"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"KrakenReview"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":25,"location":"v4:TOP::::::"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"MergeService"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":26,"location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"GK-CRUX-Analyzer"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":27,"location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"CoverlayWorker"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":28,"location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"ChangeGuardianCodeAnalyzer"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":29,"location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"BuildGuardian"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":30,"location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"CoverageBot"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":31,"location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"SomeCoverageWorker"}}}},
  {"cr_comment":{"location":{"comment_location":{"post":32,"location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"AAA","id":"LintBot"}}}}
]}}}
JSON
)
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$body")
  [ "$out" = "cr-needs-revision: 2 new" ] || fail "expected the AutoSDE and KrakenReview comments to count, got: '$out'"
  [ "$(sed -n 's/^comments=//p' "$state/task.cr-seen")" = "23 24" ] \
    || fail "sidecar should record exactly the two AAA review comments"
  pass "an unresolved AAA review comment counts on the mcurl path while status bots stay excluded"
}

# ---------------------------------------------------------------------------
# Generated check.sh behavior - destination-branch guard (Layer 2)

test_check_emits_cr_no_destination_when_package_lacks_destination() {
  # A CR whose snapshot package has an empty gitfarm_branch is unmergeable (no
  # destination branch). The guard must wake firstmate with cr-no-destination.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case no-dest)
  arm "$state" task CR-4444441 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-1 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json GroceryPackUWCTests:-)")
  assert_contains "$out" "cr-no-destination" "expected cr-no-destination when the package has no destination branch"
  assert_contains "$out" "GroceryPackUWCTests" "the signal should name the offending package"
  assert_contains "$out" "https://code.amazon.com/reviews/CR-4444441" "the signal should carry the CR url"
  assert_grep "state=missing" "$state/task.cr-dest-seen" "dest sidecar should record state=missing"
  pass "a package with no destination branch surfaces cr-no-destination"
}

test_check_silent_when_package_has_destination() {
  # The no-false-positive guarantee: a CR whose package has a real destination
  # branch (gitfarm_branch=mainline) must NOT emit cr-no-destination.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case has-dest)
  arm "$state" task CR-4444442 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-2 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json GroceryPackUWCTests:mainline)")
  assert_not_contains "$out" "cr-no-destination" "a package with a destination branch must not emit cr-no-destination"
  assert_grep "state=ok" "$state/task.cr-dest-seen" "dest sidecar should record state=ok"
  pass "a package with a destination branch stays silent (no false positive)"
}

test_check_ignores_a_dest_sidecar_another_crs_poll_wrote() {
  # An earlier CR's poll still in flight when a new CR is armed writes
  # cr-dest-seen after the arm dropped it. That state must not dedupe the new
  # CR's cr-no-destination wake.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case no-dest-other-cr)
  arm "$state" task CR-1111111 >/dev/null || fail "arming the first CR failed"
  cp "$state/task.check.sh" "$state/task-old.check.sh"
  arm "$state" task CR-2222222 >/dev/null || fail "arming the second CR failed"
  run_check "$state" task-old "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-3 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgA:-)" >/dev/null
  assert_grep 'cr=https://code.amazon.com/reviews/CR-1111111' "$state/task.cr-dest-seen" \
    "the earlier CR's poll should stamp its CR into cr-dest-seen"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-3 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgA:-)")
  assert_contains "$out" "cr-no-destination" "another CR's cr-dest-seen must not silence this CR's cr-no-destination"
  assert_grep 'cr=https://code.amazon.com/reviews/CR-2222222' "$state/task.cr-dest-seen" \
    "the poll should rewrite cr-dest-seen for its own CR"
  pass "the poll ignores a cr-dest-seen sidecar another CR's poll wrote"
}

test_check_cr_no_destination_dedupes_same_set() {
  # A persistently-broken CR must wake only once for the same missing-package
  # set; the second poll with the same set is silent.
  local state fakebin out1 out2
  { read -r state; read -r fakebin; } < <(new_case no-dest-dedupe)
  arm "$state" task CR-4444443 >/dev/null || fail "arm failed"
  out1=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-3 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgA:-)")
  assert_contains "$out1" "cr-no-destination" "first poll should wake"
  out2=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-3 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgA:-)")
  assert_not_contains "$out2" "cr-no-destination" "second poll with the same missing set should be silent"
  pass "cr-no-destination dedupes on an unchanged missing-package set"
}

test_check_cr_no_destination_multi_package_partial() {
  # A multi-package CR where only one package lacks a destination must still
  # wake, naming the offending package but not the healthy one.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case no-dest-multi)
  arm "$state" task CR-4444444 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-4 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgGood:mainline PkgBad:-)")
  assert_contains "$out" "cr-no-destination" "a partially-broken multi-package CR should wake"
  assert_contains "$out" "PkgBad" "the signal should name the package that lacks a destination"
  assert_not_contains "$out" "PkgGood" "the signal should not name the healthy package"
  pass "a multi-package CR with one destination-less package wakes and names only it"
}

test_check_cr_no_destination_fires_on_pending_only_draft() {
  # The failing case in production: a DRAFT CR whose only revision is still
  # PENDING. The status poll's non-PENDING selector exits silently for it, but
  # the destination guard runs FIRST and uses max-of-all-revisions, so it still
  # catches the missing destination on a pending-only draft.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case no-dest-pending)
  arm "$state" task CR-4444445 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY='[{"review_revision_summary":{"status":"PENDING","id":{"review_revision_id":{"revision":1}}}}]' \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot PENDING snap-5 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgDraft:-)")
  assert_contains "$out" "cr-no-destination" "a pending-only draft with no destination must still wake"
  assert_contains "$out" "PkgDraft" "the signal should name the offending package on a draft"
  pass "cr-no-destination fires on a pending-only draft CR (the production failure case)"
}

test_check_silent_when_diff_source_not_wsnap() {
  # A revision with no WSNAP diff_source cannot be assessed for a destination
  # branch. The guard must stay silent (can't-assess path), leaving the status
  # poll to surface any real error. This also pins that the pre-existing tests
  # whose revision_json carries no diff_source never trip the guard.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case no-dest-nowsnap)
  arm "$state" task CR-4444446 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "")")
  assert_not_contains "$out" "cr-no-destination" "a non-WSNAP revision must not trip the destination guard"
  [ ! -f "$state/task.cr-dest-seen" ] || fail "no dest sidecar should be written on the can't-assess path"
  pass "the destination guard stays silent when the diff source is not a WSNAP snapshot"
}

test_check_cr_no_destination_rewakes_on_changed_set() {
  # Counterpart to the comment-set net-zero test: if the missing-package SET
  # grows (PkgA, then PkgA+PkgB), the guard must wake again, not stay deduped.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case no-dest-rewake)
  arm "$state" task CR-4444447 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-6 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgA:-)")
  assert_contains "$out" "cr-no-destination" "first poll (PkgA missing) should wake"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-6 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgA:- PkgB:-)")
  assert_contains "$out" "cr-no-destination" "a grown missing set should wake again"
  assert_contains "$out" "PkgB" "the re-wake should name the newly-missing package"
  assert_grep "missing_pkgs=PkgA PkgB" "$state/task.cr-dest-seen" "sidecar should record the updated set"
  pass "cr-no-destination re-wakes when the missing-package set changes"
}

test_check_cr_no_destination_recovers_to_ok_and_silences() {
  # After the guard fires, the crewmate sets the upstream and the next poll shows
  # every package with a destination. The guard must record state=ok and go
  # silent (the missing -> ok recovery transition).
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case no-dest-recover)
  arm "$state" task CR-4444448 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-7 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgA:-)")
  assert_contains "$out" "cr-no-destination" "first poll should wake on the missing destination"
  assert_grep "state=missing" "$state/task.cr-dest-seen" "sidecar should record state=missing"
  # Upstream now set: same package has a destination branch.
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-7 "")" \
    FAKE_SNAPSHOT_BODY="$(snapshot_json PkgA:mainline)")
  assert_not_contains "$out" "cr-no-destination" "recovery to a destination branch should be silent"
  assert_grep "state=ok" "$state/task.cr-dest-seen" "sidecar should transition to state=ok"
  pass "cr-no-destination recovers to state=ok and goes silent once a destination appears"
}

test_check_silent_on_snapshot_fetch_failure() {
  # The can't-assess path: the revision has a valid WSNAP diff_source but the
  # snapshot fetch itself fails. The guard must stay silent (no false positive)
  # and write no dest sidecar, leaving the status poll to surface any real error.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case no-dest-snapfail)
  arm "$state" task CR-4444449 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json_with_snapshot IN_REVIEW snap-8 "")" \
    FAKE_SNAPSHOT_RC=22 \
    FAKE_SNAPSHOT_BODY="")
  assert_not_contains "$out" "cr-no-destination" "a snapshot-fetch failure must not emit cr-no-destination"
  [ ! -f "$state/task.cr-dest-seen" ] || fail "no dest sidecar should be written when the snapshot fetch fails"
  pass "the destination guard stays silent on a snapshot-fetch failure (no false positive)"
}

# ---------------------------------------------------------------------------
# Generated check.sh behavior - watcher-stale

test_check_emits_watcher_stale_on_mcurl_revisions_failure() {
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case stale-revisions)
  arm "$state" task CR-8888881 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_RC=22 \
    FAKE_REVISIONS_BODY="")
  assert_contains "$out" "cr-watcher-stale" "expected cr-watcher-stale on mcurl revisions failure"
  assert_contains "$out" "could not reach CRUX" "stale line should name the transport failure"
  # The stale line must also say the fallback was tried, so the captain can tell
  # "one path down" from "genuinely blind" without reading the poll's source.
  assert_contains "$out" "builder-mcp fallback" "stale line should report the fallback attempt"
  pass "mcurl revisions failure surfaces a watcher-stale signal naming both paths"
}

test_check_emits_watcher_stale_on_mcurl_revision_data_failure() {
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case stale-revision-data)
  arm "$state" task CR-8888882 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 7)" \
    FAKE_REVISION_RC=22 \
    FAKE_REVISION_BODY="")
  assert_contains "$out" "cr-watcher-stale" "expected cr-watcher-stale on revision-data mcurl failure"
  assert_contains "$out" "revision 7" "stale line should name the revision number"
  pass "mcurl revision-data failure surfaces a watcher-stale signal naming the revision"
}

test_check_emits_watcher_stale_on_jq_parse_revisions_failure() {
  # mcurl succeeds but returns a body that jq cannot parse (e.g. an HTML error
  # page or truncated response). The revisions-jq guard must surface this as
  # 'jq failed parsing revisions' rather than silently treating it as empty.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case stale-jq-revisions)
  arm "$state" task CR-8888891 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY='not valid json at all')
  assert_contains "$out" "cr-watcher-stale" "expected cr-watcher-stale on jq revisions parse failure"
  assert_contains "$out" "jq failed parsing revisions" "stale line should name the parse failure"
  pass "jq parse failure on revisions surfaces a watcher-stale signal"
}

test_check_emits_watcher_stale_on_jq_parse_status_failure() {
  # mcurl succeeds for both fetches, but the revision-data body is malformed
  # JSON. The status-jq guard must surface this as 'jq failed parsing status'.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case stale-jq-status)
  arm "$state" task CR-8888892 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 3)" \
    FAKE_REVISION_BODY='also-not-json{')
  assert_contains "$out" "cr-watcher-stale" "expected cr-watcher-stale on jq status parse failure"
  assert_contains "$out" "jq failed parsing status" "stale line should name the parse failure"
  pass "jq parse failure on revision data surfaces a watcher-stale signal"
}

test_check_emits_watcher_stale_on_empty_status() {
  # CRUX returns a parseable JSON but the status field is empty (or missing).
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case stale-empty-status)
  arm "$state" task CR-8888883 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY='{"revision":{"cr_revision":{}}}')
  assert_contains "$out" "cr-watcher-stale" "expected cr-watcher-stale on empty status"
  assert_contains "$out" "CRUX returned no status field" "stale line should explain the missing status"
  pass "empty status surfaces a watcher-stale signal"
}

test_check_emits_watcher_stale_on_unknown_status() {
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case stale-unknown-status)
  arm "$state" task CR-8888884 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json FROBNICATED "")")
  assert_contains "$out" "cr-watcher-stale" "expected cr-watcher-stale on unknown status"
  assert_contains "$out" "unknown CR status 'FROBNICATED'" "stale line should name the unknown status verbatim"
  pass "unknown status surfaces a watcher-stale signal"
}

test_check_dedupes_watcher_stale_same_reason() {
  # A persistent failure (auth dead, say) must wake only once per reason. The
  # second poll with the same reason is silent.
  local state fakebin out1 out2
  { read -r state; read -r fakebin; } < <(new_case stale-dedupe-same)
  arm "$state" task CR-8888885 >/dev/null || fail "arm failed"
  out1=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_RC=22 \
    FAKE_REVISIONS_BODY="")
  assert_contains "$out1" "cr-watcher-stale" "first stale poll should wake"
  out2=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_RC=22 \
    FAKE_REVISIONS_BODY="")
  [ -z "$out2" ] || fail "second stale poll with same reason should be silent, got: '$out2'"
  pass "watcher-stale with the same reason wakes only on the first occurrence"
}

test_check_redrives_watcher_stale_when_reason_changes() {
  local state fakebin out1 out2
  { read -r state; read -r fakebin; } < <(new_case stale-dedupe-different)
  arm "$state" task CR-8888886 >/dev/null || fail "arm failed"
  # Reason A: mcurl revisions failure.
  out1=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_RC=22 \
    FAKE_REVISIONS_BODY="")
  assert_contains "$out1" "could not reach CRUX" "first reason should surface"
  # Reason B: revisions parse but the revision-data fetch fails. Different
  # reason, must wake again.
  out2=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 4)" \
    FAKE_REVISION_RC=22 \
    FAKE_REVISION_BODY="")
  assert_contains "$out2" "revision 4" "different reason should wake again"
  pass "watcher-stale wakes again when the reason changes"
}

test_check_recovers_from_stale_to_shipped() {
  # The CR poll was stale (auth down) and then recovers to a shipped CR. The
  # shipped transition must fire even though the sidecar is mid-stale, because
  # the script's terminal-state check is prev_state != "shipped".
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case stale-recover-shipped)
  arm "$state" task CR-8888887 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_RC=22 \
    FAKE_REVISIONS_BODY="")
  assert_contains "$out" "cr-watcher-stale" "expected initial stale"
  # Auth recovers, CR is shipped.
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json SHIPPED "")")
  [ "$out" = "cr-shipped" ] || fail "recovery to shipped should fire cr-shipped, got: '$out'"
  assert_grep "state=shipped" "$state/task.cr-seen" "sidecar should now reflect shipped"
  pass "stale poll then recovery to shipped fires cr-shipped"
}

# ---------------------------------------------------------------------------
# Generated check.sh behavior - empty revisions

test_check_silent_when_no_non_pending_revision() {
  # If the CR has only PENDING revisions, jq returns empty for the revision
  # number, and the script exits silently without touching the sidecar.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case empty-revs)
  arm "$state" task CR-8888888 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY='[{"review_revision_summary":{"status":"PENDING","id":{"review_revision_id":{"revision":1}}}}]')
  [ -z "$out" ] || fail "an all-PENDING revisions list should be silent, got: '$out'"
  [ ! -f "$state/task.cr-seen" ] || fail "no sidecar should be written for a silent poll: $(cat "$state/task.cr-seen")"
  pass "all-PENDING revisions are silent and write no sidecar"
}

# ---------------------------------------------------------------------------
# Generated check.sh behavior - stale re-emit backoff
#
# The defect these pin: a PERSISTENT failure used to produce exactly one wake
# ever, then print nothing forever. Since silence is the check contract's "no
# news", a permanently broken poll became indistinguishable from a healthy quiet
# one, and five CRs went unwatched for up to 13 days. A stale condition must keep
# reminding on a backoff. FM_CR_STALE_BACKOFF keeps these tests instant.

test_check_stale_reemits_after_backoff_interval() {
  # Same unchanged reason: silent within the interval, emitted again once it has
  # elapsed. This is the whole fix for the 13-day silence.
  local state fakebin out1 out2 out3
  { read -r state; read -r fakebin; } < <(new_case stale-backoff-reemit)
  arm "$state" task CR-8888901 >/dev/null || fail "arm failed"
  out1=$(run_check "$state" task "$fakebin" FM_CR_STALE_BACKOFF="1 2 3" \
    FAKE_REVISIONS_RC=22 FAKE_REVISIONS_BODY="")
  assert_contains "$out1" "cr-watcher-stale" "first stale must wake"
  # Immediately again: inside the interval, so silent (not a per-poll firehose).
  out2=$(run_check "$state" task "$fakebin" FM_CR_STALE_BACKOFF="30 60 90" \
    FAKE_REVISIONS_RC=22 FAKE_REVISIONS_BODY="")
  [ -z "$out2" ] || fail "stale inside the backoff interval should stay silent, got: '$out2'"
  # Past the interval: must remind again, and say how long it has been broken.
  sleep 2
  out3=$(run_check "$state" task "$fakebin" FM_CR_STALE_BACKOFF="1 2 3" \
    FAKE_REVISIONS_RC=22 FAKE_REVISIONS_BODY="")
  assert_contains "$out3" "cr-watcher-stale" "stale past the backoff interval must re-emit"
  assert_contains "$out3" "persisting" "the re-emit should mark itself as a persistence reminder"
  pass "a persistent stale reason re-emits on the backoff instead of going silent forever"
}

test_check_stale_records_backoff_timestamps() {
  local state fakebin
  { read -r state; read -r fakebin; } < <(new_case stale-backoff-sidecar)
  arm "$state" task CR-8888902 >/dev/null || fail "arm failed"
  run_check "$state" task "$fakebin" FAKE_REVISIONS_RC=22 FAKE_REVISIONS_BODY="" >/dev/null
  assert_grep "stale_since=" "$state/task.cr-seen" "sidecar should record when the stale reason was first seen"
  assert_grep "stale_emitted=" "$state/task.cr-seen" "sidecar should record when the stale was last emitted"
  pass "the stale sidecar records the backoff timestamps"
}

test_check_stale_preexisting_sidecar_reenters_reminder_cycle() {
  # The five live blind polls: their sidecars predate the backoff and carry
  # state=stale with NO timestamps. Such a poll must re-enter the reminder cycle
  # on its very next run rather than staying silent forever, otherwise the fix
  # would not reach the CRs that motivated it.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case stale-legacy-sidecar)
  arm "$state" task CR-8888903 >/dev/null || fail "arm failed"
  # Exactly the shape observed live on 2026-08-04.
  printf 'state=stale\nstale_reason=mcurl could not reach CRUX fetching revisions (network? timeout?); builder-mcp fallback unavailable (no OO7 builder CLI on PATH)\n' \
    > "$state/task.cr-seen"
  out=$(run_check "$state" task "$fakebin" FAKE_REVISIONS_RC=22 FAKE_REVISIONS_BODY="")
  assert_contains "$out" "cr-watcher-stale" "a timestamp-less legacy stale sidecar must re-emit, not stay silent"
  assert_grep "stale_emitted=" "$state/task.cr-seen" "the re-emit should backfill the backoff timestamps"
  pass "a pre-backoff stale sidecar re-enters the reminder cycle on its next poll"
}

test_check_stale_preserves_comment_set() {
  # A stale poll learned nothing about comments, so the recorded set must be
  # carried through. Blanking it would replay every already-known comment as new
  # once the fetch recovered.
  local state fakebin
  { read -r state; read -r fakebin; } < <(new_case stale-keeps-comments)
  arm "$state" task CR-8888904 >/dev/null || fail "arm failed"
  run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "c1 c2")" >/dev/null
  assert_grep "comments=c1 c2" "$state/task.cr-seen" "precondition: comment set recorded"
  run_check "$state" task "$fakebin" FAKE_REVISIONS_RC=22 FAKE_REVISIONS_BODY="" >/dev/null
  assert_grep "state=stale" "$state/task.cr-seen" "poll should be stale"
  assert_grep "comments=c1 c2" "$state/task.cr-seen" "the comment set must survive a stale period"
  pass "a stale period preserves the tracked comment set"
}

# ---------------------------------------------------------------------------
# Generated check.sh behavior - the builder-mcp fallback credential path
#
# mcurl and builder-mcp are independent credential paths that fail independently,
# each able to cover the other. The failure that motivated this: mcurl returned
# 403 for every code.amazon.com URL because of an Amazon Enterprise Access
# POSTURE rejection - which `mwinit` does not clear - while builder-mcp read every
# CR perfectly. Declaring the CR unreadable there reports blind.

# make_fake_fallback <dir> <body>: install a stub builder-mcp server that
# answers the ReadInternalWebsites call with <body> over stdio JSON-RPC, then
# idles until its input closes, as the real server does. Echoes its path.
make_fake_fallback() {
  local dir=$1 body=$2 stub="$1/fake-builder-mcp"
  printf '%s' "$body" > "$dir/fake-builder-mcp.body"
  cat > "$stub" <<SH
#!/usr/bin/env bash
while IFS= read -r line; do
  case "\$line" in
    *'"id":2'*)
      jq -cn --rawfile t $(printf '%q' "$dir/fake-builder-mcp.body") \
        '{result:{content:[{type:"text",text:\$t}],isError:false},jsonrpc:"2.0",id:2}'
      ;;
  esac
done
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

# posture_body: the AEA posture interstitial mcurl actually returns. Detection is
# on the BODY, not the status code, because a dead cookie yields the same 403.
posture_body() {
  printf '%s' '<html><head><title>Midway Authentication Portal</title></head><body><div id="posture_error">If you work for Amazon, you must use Amazon Enterprise Access (AEA) to reach this site.</div></body></html>'
}

# fallback_json <status> [pkg:dest ...]: a builder-mcp-shaped CR body. Status
# lives at .content.revisionSummary.status and the snapshot is inlined.
fallback_json() {
  local status=$1
  shift
  local content='[]' spec pkg dest entry
  for spec in "$@"; do
    pkg=${spec%%:*}; dest=${spec#*:}
    [ "$dest" = "-" ] && dest=""
    entry=$(jq -cn --arg pkg "$pkg" --arg dest "$dest" \
      '{content:{package_name:$pkg, branches:[{branch:{local_branch:"fm/task-src", gitfarm_branch:$dest}}]}}')
    content=$(printf '%s\n%s\n' "$content" "$entry" | jq -sc '.[0] + [.[1]]')
  done
  jq -cn --arg st "$status" --argjson content "$content" \
    '{content:{crId:"CR-x", revision:1, latestRevision:1,
               revisionSummary:{status:$st},
               snapshotDetails:{snapshot:{content:$content}}}}'
}

# fallback_json_with_comments <status> <json-comments-array>: a builder-mcp-shaped
# body that also carries allComments, for the opt-in comment-bearing fallback read.
fallback_json_with_comments() {
  local status=$1 comments=$2
  jq -cn --arg st "$status" --argjson c "$comments" \
    '{content:{crId:"CR-x", revision:1, latestRevision:1,
               revisionSummary:{status:$st},
               allComments:$c,
               snapshotDetails:{snapshot:{content:[{content:{package_name:"PkgA", branches:[{branch:{local_branch:"fm/x", gitfarm_branch:"mainline"}}]}}]}}}}'
}

test_check_falls_back_to_builder_mcp_on_posture_403() {
  # The headline case: mcurl is posture-blocked, builder-mcp works, and the CR is
  # shipped. The poll must report cr-shipped rather than going stale - the old
  # code reported blind while the CR was readable the whole time.
  local state fakebin stub out
  { read -r state; read -r fakebin; } < <(new_case fallback-posture)
  arm "$state" task CR-4000001 >/dev/null || fail "arm failed"
  stub=$(make_fake_fallback "$state" "$(fallback_json SHIPPED PkgA:mainline)")
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  [ "$out" = "cr-shipped" ] || fail "posture-blocked mcurl with a working fallback should still report cr-shipped, got: '$out'"
  assert_grep "state=shipped" "$state/task.cr-seen" "sidecar should record the shipped state read via the fallback"
  pass "an AEA posture 403 falls back to builder-mcp and still detects the ship"
}

test_check_truncated_fallback_reply_is_not_trusted() {
  # The server dies by SIGTERM partway through a SHIPPED reply, so the read
  # never completes and the poll must not ship.
  local state fakebin stub out
  { read -r state; read -r fakebin; } < <(new_case fallback-signal)
  arm "$state" task CR-4000009 >/dev/null || fail "arm failed"
  stub="$state/fake-builder-mcp-truncated"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    *'"id":2'*)
      printf '%s' '{"result":{"content":[{"type":"text","text":"{\"content\":{\"revisionSummary\":{\"status\":\"SHIPPED\"'
      kill -TERM $$
      ;;
  esac
done
SH
  chmod +x "$stub"
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  assert_not_contains "$out" "cr-shipped" "a truncated fallback reply must not report a ship"
  assert_contains "$out" "cr-watcher-stale" "a truncated fallback reply must surface as stale"
  pass "a builder-mcp reply cut off by a signal is a failed read, not a ship"
}

test_check_posture_403_is_named_distinctly_from_expiry() {
  # Posture and expiry are both 403 with OPPOSITE remedies: route around it vs
  # the captain runs mwinit. Collapsing them into one generic "auth expired?"
  # string is what made 13 days of blindness look like a single mystery, so the
  # stale line must name which mode it saw.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case fallback-posture-named)
  arm "$state" task CR-4000002 >/dev/null || fail "arm failed"
  # No usable fallback, so the poll goes stale and must explain WHY precisely.
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  assert_contains "$out" "posture" "a posture 403 must be named as a posture failure"
  assert_contains "$out" "mwinit will not fix" "the stale line must say mwinit does not clear a posture failure"
  pass "an AEA posture 403 is reported distinctly from credential expiry"
}

test_check_plain_auth_403_names_mwinit() {
  # A non-posture 401/403 IS cookie expiry, and its remedy is mwinit. The line
  # must say so - the actionable counterpart to the posture case above.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case fallback-expiry-named)
  arm "$state" task CR-4000003 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY='{"message":"Forbidden"}')
  assert_contains "$out" "mwinit" "a plain auth 403 should point at mwinit"
  assert_not_contains "$out" "posture" "a plain auth 403 must not be mislabeled a posture failure"
  pass "a plain auth 403 is reported as expiry and names mwinit"
}

test_check_stale_when_both_credential_paths_fail() {
  # Only when BOTH paths are down is the poll genuinely blind, and it must say so
  # explicitly rather than blaming mcurl alone.
  local state fakebin stub out
  { read -r state; read -r fakebin; } < <(new_case fallback-both-down)
  arm "$state" task CR-4000004 >/dev/null || fail "arm failed"
  stub="$state/failing-builder"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub"
  chmod +x "$stub"
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  assert_contains "$out" "cr-watcher-stale" "both paths down must surface a stale"
  assert_contains "$out" "both credential paths are down" "the stale line must say both paths were tried"
  pass "a genuine outage of both credential paths reports stale naming both"
}

test_check_fallback_detects_missing_destination() {
  # The destination guard must keep working through an mcurl outage: the fallback
  # body inlines the same snapshot, so an unmergeable CR is still caught.
  local state fakebin stub out
  { read -r state; read -r fakebin; } < <(new_case fallback-no-dest)
  arm "$state" task CR-4000005 >/dev/null || fail "arm failed"
  stub=$(make_fake_fallback "$state" "$(fallback_json OPEN PkgBad:-)")
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  assert_contains "$out" "cr-no-destination" "the destination guard should still fire via the fallback"
  assert_contains "$out" "PkgBad" "the fallback-derived signal should name the offending package"
  pass "the destination-branch guard survives an mcurl outage via the fallback"
}

MERGE_FIXTURES="$ROOT/tests/fixtures/cr-analyzers"

test_check_emits_cr_merge_failed_once_and_resets_on_new_revision() {
  # CRUX can fail a merge while every analyzer is green; the poll must say so
  # once, and a new revision supersedes the failure.
  local state fakebin body out
  { read -r state; read -r fakebin; } < <(new_case merge-failed)
  arm "$state" task CR-7100001 >/dev/null || fail "arm failed"
  body=$(cat "$MERGE_FIXTURES/merge-conflict-could-not-run.json")
  out=$(run_check "$state" task "$fakebin" FAKE_REVISIONS_BODY="$(revisions_json 2)" FAKE_REVISION_BODY="$body")
  assert_contains "$out" "cr-merge-failed: https://code.amazon.com/reviews/CR-7100001 - conflict - Package ExamplePackage had merge conflicts" \
    "a merge conflict must wake with the review and the conflicting package"
  assert_contains "$out" "auto-merge was cleared" "the cleared auto-merge is named"
  assert_grep "state=failed" "$state/task.cr-merge-seen" "the merge sidecar records the failure"
  out=$(run_check "$state" task "$fakebin" FAKE_REVISIONS_BODY="$(revisions_json 2)" FAKE_REVISION_BODY="$body")
  assert_not_contains "$out" "cr-merge-failed" "an unchanged merge failure stays silent"
  body=$(printf '%s' "$body" | jq -c '.revision.cr_revision.id.review_revision_id.revision = 3')
  out=$(run_check "$state" task "$fakebin" FAKE_REVISIONS_BODY="$(revisions_json 3)" FAKE_REVISION_BODY="$body")
  assert_not_contains "$out" "cr-merge-failed" "a new revision supersedes the failure"
  assert_grep "state=ok" "$state/task.cr-merge-seen" "the merge sidecar resets once the failure no longer applies"
  pass "a CRUX merge failure wakes once as cr-merge-failed and resets on a new revision"
}

test_check_fallback_detects_merge_failed_banner() {
  local state fakebin stub out
  { read -r state; read -r fakebin; } < <(new_case fallback-merge-failed)
  arm "$state" task CR-7100002 >/dev/null || fail "arm failed"
  stub=$(make_fake_fallback "$state" "$(cat "$MERGE_FIXTURES/merge-failed-banner-fallback.json")")
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  assert_contains "$out" "cr-merge-failed: https://code.amazon.com/reviews/CR-7100002 - conflict - Package ExamplePackage had merge conflicts" \
    "the merge failure must still surface through the builder-mcp fallback"
  pass "the merge-failure check survives an mcurl outage via the fallback"
}

test_check_fallback_without_comments_reports_degraded_not_silence() {
  # The affordable fallback read carries no comments (buying them risks the
  # watcher's hard check timeout, and a killed check prints NOTHING - the exact
  # blindness being fixed). So comment tracking is degraded, and that must be
  # reported rather than looking like "no new comments".
  local state fakebin stub out
  { read -r state; read -r fakebin; } < <(new_case fallback-degraded-comments)
  arm "$state" task CR-4000006 >/dev/null || fail "arm failed"
  stub=$(make_fake_fallback "$state" "$(fallback_json OPEN PkgA:mainline)")
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  assert_contains "$out" "cr-watcher-stale" "degraded comment tracking must surface, not stay silent"
  assert_contains "$out" "reviewer-comment tracking blind" "the line should say comment tracking specifically is blind"
  pass "a fallback poll without comment data reports degraded tracking instead of silence"
}

test_check_fallback_does_not_drop_known_comments() {
  # Regression guard: a fallback poll with no comment data must not blank the
  # recorded set. Dropping it would silently discard known-open reviewer comments.
  local state fakebin stub
  { read -r state; read -r fakebin; } < <(new_case fallback-keeps-comments)
  arm "$state" task CR-4000007 >/dev/null || fail "arm failed"
  run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$(revision_json IN_REVIEW "k1 k2")" >/dev/null
  assert_grep "comments=k1 k2" "$state/task.cr-seen" "precondition: comments recorded via mcurl"
  stub=$(make_fake_fallback "$state" "$(fallback_json OPEN PkgA:mainline)")
  run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)" >/dev/null
  assert_grep "comments=k1 k2" "$state/task.cr-seen" "a comment-less fallback poll must not drop the known set"
  pass "a fallback poll without comment data preserves the known comment set"
}

# ---------------------------------------------------------------------------
# Comment-id field (the selector that silently matched nothing)

test_check_reads_comment_id_from_real_crux_field() {
  # The bug: the poll selected `.id // .post_id`, neither of which CRUX emits -
  # the id is at .location.comment_location.post. So every CR reported zero
  # unresolved comments, forever, silently. Verified against four live CRs;
  # CR-266137656 had 13 unresolved comments reported as none.
  local state fakebin out body
  { read -r state; read -r fakebin; } < <(new_case comment-id-field)
  arm "$state" task CR-4100001 >/dev/null || fail "arm failed"
  # A comment carrying ONLY the real field, and no .id/.post_id anywhere.
  body='{"revision":{"cr_revision":{"status":"IN_REVIEW","comments":[
    {"cr_comment":{"location":{"comment_location":{"post":42,"location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"USER"}}}}
  ]}}}'
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$body")
  [ "$out" = "cr-needs-revision: 1 new" ] \
    || fail "an unresolved comment identified only by location.comment_location.post must be seen, got: '$out'"
  assert_grep "comments=42" "$state/task.cr-seen" "sidecar should record the real CRUX post id"
  pass "unresolved comments are read from the real CRUX id field"
}

test_check_counts_thread_whose_reply_is_unresolved_under_fixed_parent() {
  # A reviewer marks the top-level post fixed but leaves the live objection in a
  # REPLY. Filtering to parent == null alone would drop the parent (fixed) and the
  # reply (a reply), reporting the thread resolved when it is not - the same
  # silent-zero class as the field-name bug. The thread must surface, keyed by its
  # root so it is still counted exactly once.
  local state fakebin out body
  { read -r state; read -r fakebin; } < <(new_case reply-under-fixed-parent)
  arm "$state" task CR-4200001 >/dev/null || fail "arm failed"
  body='{"revision":{"cr_revision":{"status":"IN_REVIEW","comments":[
    {"cr_comment":{"location":{"comment_location":{"post":100,"location":"TOP"}},"fixed":true,"parent":null,"author":{"entity_id":{"type":"USER"}}}},
    {"cr_comment":{"location":{"comment_location":{"post":101,"location":"TOP"}},"fixed":false,"parent":100,"author":{"entity_id":{"type":"USER"}}}}
  ]}}}'
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$body")
  [ "$out" = "cr-needs-revision: 1 new" ] \
    || fail "an unresolved reply under a fixed parent must still wake, got: '$out'"
  assert_grep "comments=100" "$state/task.cr-seen" "the thread should be recorded by its root id"
  pass "a thread whose reply is unresolved under a fixed parent still wakes"
}

test_check_thread_counted_once_when_root_and_reply_both_unresolved() {
  # The counterpart guarantee: folding replies onto the root must NOT double-count
  # a thread that has both an unresolved root and an unresolved reply. This is what
  # the original parent == null filter got right, and it has to stay right.
  local state fakebin out body
  { read -r state; read -r fakebin; } < <(new_case thread-counted-once)
  arm "$state" task CR-4200002 >/dev/null || fail "arm failed"
  body='{"revision":{"cr_revision":{"status":"IN_REVIEW","comments":[
    {"cr_comment":{"location":{"comment_location":{"post":200,"location":"TOP"}},"fixed":false,"parent":null,"author":{"entity_id":{"type":"USER"}}}},
    {"cr_comment":{"location":{"comment_location":{"post":201,"location":"TOP"}},"fixed":false,"parent":200,"author":{"entity_id":{"type":"USER"}}}}
  ]}}}'
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$body")
  [ "$out" = "cr-needs-revision: 1 new" ] \
    || fail "a thread with an unresolved root AND reply must count once, got: '$out'"
  assert_grep "comments=200" "$state/task.cr-seen" "only the thread root should be recorded"
  assert_no_grep "201" "$state/task.cr-seen" "the reply must not be recorded as a separate thread"
  pass "a thread with both root and reply unresolved is counted exactly once"
}

test_check_fallback_comment_ids_filter_and_uniqueness() {
  # The comment-bearing fallback read (opt-in). The synthetic key is author +
  # created_at + location because the fallback exposes no post ids, so this pins
  # that human unresolved comments count, fixed ones and bots do not, and two
  # distinct comments never collide onto one key (a collision would merge threads
  # and under-report).
  local state fakebin stub out comments
  { read -r state; read -r fakebin; } < <(new_case fallback-comment-ids)
  arm "$state" task CR-4300001 >/dev/null || fail "arm failed"
  comments='[
    {"author":"alice","created_at":"2026-08-01T10:00:00.000Z","location":"TOP","fixed":false},
    {"author":"alice","created_at":"2026-08-01T11:00:00.000Z","location":"TOP","fixed":false},
    {"author":"bob","created_at":"2026-08-01T10:00:00.000Z","location":"src/A.kt:12","fixed":false},
    {"author":"carol","created_at":"2026-08-01T12:00:00.000Z","location":"TOP","fixed":true},
    {"author":"CoverlayWorker","created_at":"2026-08-01T13:00:00.000Z","location":"TOP","fixed":false},
    {"author":"AutoSDE","created_at":"2026-08-01T14:00:00.000Z","location":"TOP","fixed":false},
    {"author":"MergeService","created_at":"2026-08-01T15:00:00.000Z","location":"v4:TOP::::::","fixed":false}
  ]'
  # First poll on the fallback re-baselines the id vocabulary (the two paths mint
  # non-comparable keys), so establish that baseline with an empty set, then assert
  # the count on the next fallback poll where the comparison is like-for-like.
  stub=$(make_fake_fallback "$state" "$(fallback_json_with_comments OPEN '[]')")
  run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FM_CR_FALLBACK_COMMENTS=1 \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)" >/dev/null
  assert_grep "source=fallback" "$state/task.cr-seen" "precondition: the poll is now baselined on the fallback path"
  stub=$(make_fake_fallback "$state" "$(fallback_json_with_comments OPEN "$comments")")
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FM_CR_FALLBACK_COMMENTS=1 \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  # Three unresolved human comments plus the AutoSDE finding; the fixed one and
  # both status bots drop out.
  [ "$out" = "cr-needs-revision: 4 new" ] \
    || fail "expected 4 unresolved review comments via the fallback, got: '$out'"
  assert_no_grep "CoverlayWorker" "$state/task.cr-seen" "a coverage bot must not count as a reviewer comment"
  assert_no_grep "MergeService" "$state/task.cr-seen" "an auto-merge notice must not count as a reviewer comment"
  assert_grep "AutoSDE@2026-08-01T14:00:00.000Z" "$state/task.cr-seen" "an AutoSDE finding must count on the fallback path"
  assert_no_grep "carol" "$state/task.cr-seen" "a fixed comment must not count as unresolved"
  # Same author + same location but different timestamps must stay distinct.
  assert_grep "alice@2026-08-01T10:00:00.000Z" "$state/task.cr-seen" "the first alice comment should have its own key"
  assert_grep "alice@2026-08-01T11:00:00.000Z" "$state/task.cr-seen" "the second alice comment must not collide with the first"
  pass "the fallback comment-id set counts review comments only and keys each comment distinctly"
}

test_check_counts_two_hop_reply_thread() {
  # A reply nested two levels under a fixed thread root must still surface, keyed by
  # the root. An unresolved comment at any depth is an unanswered reviewer comment.
  local state fakebin out body
  { read -r state; read -r fakebin; } < <(new_case thread-two-hop)
  arm "$state" task CR-4300002 >/dev/null || fail "arm failed"
  body='{"revision":{"cr_revision":{"status":"IN_REVIEW","comments":[
    {"cr_comment":{"location":{"comment_location":{"post":300,"location":"TOP"}},"fixed":true,"parent":null,"author":{"entity_id":{"type":"USER"}}}},
    {"cr_comment":{"location":{"comment_location":{"post":301,"location":"TOP"}},"fixed":true,"parent":300,"author":{"entity_id":{"type":"USER"}}}},
    {"cr_comment":{"location":{"comment_location":{"post":302,"location":"TOP"}},"fixed":false,"parent":301,"author":{"entity_id":{"type":"USER"}}}}
  ]}}}'
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$body")
  [ "$out" = "cr-needs-revision: 1 new" ] \
    || fail "a two-hop unresolved reply must surface once, got: '$out'"
  assert_grep "comments=300" "$state/task.cr-seen" "the thread should be keyed by its root"
  pass "an unresolved reply two levels deep surfaces, keyed by the thread root"
}

test_check_counts_reply_whose_parent_is_absent() {
  # A reply whose parent is not in this revision must fall back to its own id rather
  # than vanish - dropping it would be the same silent-zero class of bug.
  local state fakebin out body
  { read -r state; read -r fakebin; } < <(new_case thread-orphan-reply)
  arm "$state" task CR-4300003 >/dev/null || fail "arm failed"
  body='{"revision":{"cr_revision":{"status":"IN_REVIEW","comments":[
    {"cr_comment":{"location":{"comment_location":{"post":401,"location":"TOP"}},"fixed":false,"parent":999,"author":{"entity_id":{"type":"USER"}}}}
  ]}}}'
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_BODY="$body")
  [ "$out" = "cr-needs-revision: 1 new" ] \
    || fail "a reply with an absent parent must still surface, got: '$out'"
  assert_grep "comments=401" "$state/task.cr-seen" "it should fall back to its own post id"
  pass "an unresolved reply whose parent is absent falls back to its own id"
}

test_check_probe_classifies_401_as_denied() {
  # 401 and 403 both mean auth rejected; only the posture BODY distinguishes the
  # mwinit-fixable mode, so 401 must reach the same expiry wording as 403.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case probe-401)
  arm "$state" task CR-4300004 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_HTTP_CODE=401 \
    FAKE_REVISIONS_BODY='{"message":"Unauthorized"}')
  assert_contains "$out" "mwinit" "a 401 should be reported as expiry and name mwinit"
  assert_not_contains "$out" "posture" "a non-posture 401 must not be labeled a posture failure"
  pass "a 401 classifies as auth expiry, same as a non-posture 403"
}

test_check_probe_detects_posture_body_on_200() {
  # The portal can answer 200 with an interstitial, so the body is checked even on
  # success before it is trusted as payload.
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case probe-200-posture)
  arm "$state" task CR-4300005 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_HTTP_CODE=200 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  assert_contains "$out" "posture" "a 200 carrying a posture interstitial must be treated as posture"
  pass "a posture interstitial served with 200 is still detected"
}

test_check_fallback_pending_draft_reports_degraded() {
  # A draft CR's latest revision is PENDING, so the fallback cannot assess CR state.
  # That must report the degraded reason, not a bogus "unknown CR status 'PENDING'"
  # and not silence.
  local state fakebin stub out
  { read -r state; read -r fakebin; } < <(new_case fallback-pending)
  arm "$state" task CR-4300006 >/dev/null || fail "arm failed"
  stub=$(make_fake_fallback "$state" "$(fallback_json PENDING PkgA:mainline)")
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 \
    FAKE_REVISIONS_BODY="$(posture_body)")
  assert_contains "$out" "cr-watcher-stale" "a PENDING-only fallback view must surface, not stay silent"
  assert_contains "$out" "unpublished (PENDING)" "the reason should name the unpublished revision"
  assert_not_contains "$out" "unknown CR status" "PENDING must not be reported as an unknown lifecycle state"
  pass "a fallback seeing only a PENDING draft reports the degraded reason"
}

# ---------------------------------------------------------------------------
# CR-id injection surface (the ID is interpolated into the generated script)

# ---------------------------------------------------------------------------
# Draft (PENDING) latest revisions. CRUX replaces a draft in place on `cr -r`,
# so reviewer comments on a draft must wake firstmate before an upload hides them.

test_check_draft_only_cr_wakes_on_reviewer_comment() {
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case draft-only)
  arm "$state" task CR-4500001 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY='[{"review_revision_summary":{"status":"PENDING","id":{"review_revision_id":{"revision":1}}}}]' \
    FAKE_REVISION_BODY="$(revision_json PENDING "1 2")")
  assert_contains "$out" "cr-needs-revision: 2 new" "reviewer comments on a draft-only CR must wake"
  assert_grep "state=draft" "$state/task.cr-seen" "the sidecar should record the draft state"
  assert_grep "comments=1 2" "$state/task.cr-seen" "a draft-only CR keeps bare post ids"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY='[{"review_revision_summary":{"status":"PENDING","id":{"review_revision_id":{"revision":1}}}}]' \
    FAKE_REVISION_BODY="$(revision_json PENDING "1 2")")
  [ -z "$out" ] || fail "the same draft comments must not wake twice, got: '$out'"
  pass "a draft-only CR wakes cr-needs-revision on reviewer comments, once"
}

test_check_draft_above_published_revision_wakes_with_draft_note() {
  local state fakebin out revs
  { read -r state; read -r fakebin; } < <(new_case draft-above)
  arm "$state" task CR-4500002 >/dev/null || fail "arm failed"
  run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 1)" \
    FAKE_REVISION_1_BODY="$(revision_json OPEN "7")" >/dev/null
  assert_grep "comments=7" "$state/task.cr-seen" "precondition: the published comment set is recorded"
  revs='[{"review_revision_summary":{"status":"OPEN","id":{"review_revision_id":{"revision":1}}}},{"review_revision_summary":{"status":"PENDING","id":{"review_revision_id":{"revision":2}}}}]'
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$revs" \
    FAKE_REVISION_1_BODY="$(revision_json OPEN "7")" \
    FAKE_REVISION_2_BODY="$(revision_json PENDING "1")")
  assert_contains "$out" "cr-needs-revision: 1 new" "a reviewer comment on the draft revision must wake"
  assert_contains "$out" "on unpublished draft revision 2, which cr -r would replace in place" "the wake should say the comment is on a draft"
  assert_grep "comments=2:1 7" "$state/task.cr-seen" "the draft comment is keyed <revision>:<post>"
  assert_grep "state=in-review" "$state/task.cr-seen" "the published revision still sets the lifecycle state"
  revs='[{"review_revision_summary":{"status":"OPEN","id":{"review_revision_id":{"revision":1}}}},{"review_revision_summary":{"status":"OPEN","id":{"review_revision_id":{"revision":2}}}}]'
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$revs" \
    FAKE_REVISION_2_BODY="$(revision_json OPEN "1")")
  [ -z "$out" ] || fail "publishing the draft must not report its known comment again, got: '$out'"
  assert_grep "comments=1" "$state/task.cr-seen" "the published revision's comment keeps its identity"
  pass "a draft above a published revision wakes on its reviewer comment once, including after it is published"
}

test_check_draft_fetch_failure_keeps_published_reading() {
  # A draft-only fetch failure must not discard the published reading.
  local state fakebin out revs
  { read -r state; read -r fakebin; } < <(new_case draft-fetch-fail)
  arm "$state" task CR-4500005 >/dev/null || fail "arm failed"
  revs='[{"review_revision_summary":{"status":"OPEN","id":{"review_revision_id":{"revision":1}}}},{"review_revision_summary":{"status":"PENDING","id":{"review_revision_id":{"revision":2}}}}]'
  run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$revs" \
    FAKE_REVISION_1_BODY="$(revision_json OPEN "7")" \
    FAKE_REVISION_2_BODY="$(revision_json PENDING "1")" >/dev/null
  assert_grep "comments=2:1 7" "$state/task.cr-seen" "precondition: the draft comment is recorded"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$revs" \
    FAKE_REVISION_1_BODY="$(revision_json OPEN "7 8")" \
    FAKE_REVISION_2_RC=7)
  assert_contains "$out" "cr-needs-revision: 1 new" "the new published comment must still wake"
  assert_contains "$out" "draft revision 2, so reviewer comments on it are unassessed" "the poll must say the draft went unassessed"
  assert_not_contains "$out" "mcurl is down" "a draft-only fetch failure is not a credential outage"
  assert_grep "comments=2:1 7 8" "$state/task.cr-seen" "the draft's known comment is carried forward"
  pass "a failed draft fetch keeps the published reading and names the unassessed draft"
}

test_check_draft_only_fetch_failure_keeps_known_comments() {
  local state fakebin out revs
  { read -r state; read -r fakebin; } < <(new_case draft-only-fetch-fail)
  arm "$state" task CR-4500006 >/dev/null || fail "arm failed"
  revs='[{"review_revision_summary":{"status":"PENDING","id":{"review_revision_id":{"revision":1}}}}]'
  run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$revs" FAKE_REVISION_1_BODY="$(revision_json PENDING "1 2")" >/dev/null
  assert_grep "comments=1 2" "$state/task.cr-seen" "precondition: the draft comments are recorded"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$revs" FAKE_REVISION_1_RC=7)
  assert_contains "$out" "the CR's only revision, so nothing on the CR was assessed" "the reason must not claim a published revision was read"
  assert_not_contains "$out" "published revision was read" "a draft-only CR has no published revision"
  assert_grep "comments=1 2" "$state/task.cr-seen" "the known draft comments are carried forward"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$revs" FAKE_REVISION_1_BODY="$(revision_json PENDING "1 2")")
  assert_not_contains "$out" "cr-needs-revision" "recovered known comments must not wake again"
  pass "a failed fetch of a draft-only CR keeps its known comments and names the unassessed CR"
}

test_check_published_only_comment_ids_are_unchanged_by_draft_support() {
  local state fakebin out
  { read -r state; read -r fakebin; } < <(new_case published-ids)
  arm "$state" task CR-4500003 >/dev/null || fail "arm failed"
  out=$(run_check "$state" task "$fakebin" \
    FAKE_REVISIONS_BODY="$(revisions_json 3)" \
    FAKE_REVISION_BODY="$(revision_json OPEN "5 9")")
  [ "$out" = "cr-needs-revision: 2 new" ] || fail "a published-only CR's wake must be unchanged, got: '$out'"
  assert_grep "comments=5 9" "$state/task.cr-seen" "published comment ids stay bare post ids"
  pass "a published-only CR keeps its wake line and bare comment ids"
}

test_check_fallback_draft_with_comments_wakes() {
  # A first fallback poll re-baselines the comment set (the fallback's ids are
  # not comparable with mcurl's), and still says the latest revision is a draft.
  # A reviewer comment that arrives after that wakes cr-needs-revision.
  local state fakebin stub out one two
  { read -r state; read -r fakebin; } < <(new_case fallback-draft-comments)
  arm "$state" task CR-4500004 >/dev/null || fail "arm failed"
  one='{"author":"CoverlayWorker","created_at":"2026-09-29T18:40:00Z","location":"TOP","fixed":false}'
  two='{"author":"smmalyal","created_at":"2026-09-29T18:53:24Z","location":"Pkg:a.kt:5","fixed":false}'
  stub=$(make_fake_fallback "$state" "$(fallback_json_with_comments PENDING "[$one]")")
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" FAKE_REVISIONS_HTTP_CODE=403 FAKE_REVISIONS_BODY="$(posture_body)")
  assert_contains "$out" "re-baselined" "the first fallback poll re-baselines"
  assert_contains "$out" "unpublished draft" "the re-baseline line says the latest revision is a draft"
  assert_not_contains "$out" "cr-watcher-stale" "a readable draft is not a stale poll"
  stub=$(make_fake_fallback "$state" "$(fallback_json_with_comments PENDING "[$one,$two]")")
  out=$(run_check "$state" task "$fakebin" \
    FM_CR_FALLBACK_BIN="$stub" FAKE_REVISIONS_HTTP_CODE=403 FAKE_REVISIONS_BODY="$(posture_body)")
  assert_contains "$out" "cr-needs-revision: 1 new" "a new reviewer comment on the draft must wake"
  assert_contains "$out" "unpublished draft, which cr -r would replace in place" "the wake says the comment is on a draft"
  assert_grep "state=draft" "$state/task.cr-seen" "the sidecar records the draft state"
  pass "a comment-bearing fallback read of a draft tracks and wakes on its reviewer comments"
}


test_check_ignores_a_sidecar_another_cr_wrote
test_check_sidecar_names_its_cr
test_check_emits_cr_shipped_on_shipped_or_merged_and_dedupes
test_check_emits_cr_abandoned_on_terminal_negative_states_and_dedupes
test_check_in_review_emits_needs_revision_on_first_unresolved_comments
test_check_in_review_handles_all_status_synonyms
test_check_in_review_same_set_is_silent
test_check_in_review_set_membership_catches_net_zero_churn
test_check_in_review_shrink_only_no_wake
test_check_in_review_ignores_resolved_and_replies_and_unknown_author_types
test_check_counts_unresolved_aaa_review_comment_and_drops_status_bots
test_check_emits_cr_no_destination_when_package_lacks_destination
test_check_silent_when_package_has_destination
test_check_ignores_a_dest_sidecar_another_crs_poll_wrote
test_check_cr_no_destination_dedupes_same_set
test_check_cr_no_destination_multi_package_partial
test_check_cr_no_destination_fires_on_pending_only_draft
test_check_silent_when_diff_source_not_wsnap
test_check_cr_no_destination_rewakes_on_changed_set
test_check_cr_no_destination_recovers_to_ok_and_silences
test_check_silent_on_snapshot_fetch_failure
test_check_emits_watcher_stale_on_mcurl_revisions_failure
test_check_emits_watcher_stale_on_mcurl_revision_data_failure
test_check_emits_watcher_stale_on_jq_parse_revisions_failure
test_check_emits_watcher_stale_on_jq_parse_status_failure
test_check_emits_watcher_stale_on_empty_status
test_check_emits_watcher_stale_on_unknown_status
test_check_dedupes_watcher_stale_same_reason
test_check_redrives_watcher_stale_when_reason_changes
test_check_recovers_from_stale_to_shipped
test_check_silent_when_no_non_pending_revision
test_check_stale_reemits_after_backoff_interval
test_check_stale_records_backoff_timestamps
test_check_stale_preexisting_sidecar_reenters_reminder_cycle
test_check_stale_preserves_comment_set
test_check_falls_back_to_builder_mcp_on_posture_403
test_check_emits_cr_merge_failed_once_and_resets_on_new_revision
test_check_fallback_detects_merge_failed_banner
test_check_truncated_fallback_reply_is_not_trusted
test_check_posture_403_is_named_distinctly_from_expiry
test_check_plain_auth_403_names_mwinit
test_check_stale_when_both_credential_paths_fail
test_check_fallback_detects_missing_destination
test_check_fallback_without_comments_reports_degraded_not_silence
test_check_fallback_does_not_drop_known_comments
test_check_reads_comment_id_from_real_crux_field
test_check_counts_thread_whose_reply_is_unresolved_under_fixed_parent
test_check_thread_counted_once_when_root_and_reply_both_unresolved
test_check_fallback_comment_ids_filter_and_uniqueness
test_check_counts_two_hop_reply_thread
test_check_counts_reply_whose_parent_is_absent
test_check_probe_classifies_401_as_denied
test_check_probe_detects_posture_body_on_200
test_check_fallback_pending_draft_reports_degraded
test_check_draft_only_cr_wakes_on_reviewer_comment
test_check_draft_above_published_revision_wakes_with_draft_note
test_check_draft_fetch_failure_keeps_published_reading
test_check_draft_only_fetch_failure_keeps_known_comments
test_check_published_only_comment_ids_are_unchanged_by_draft_support
test_check_fallback_draft_with_comments_wakes
