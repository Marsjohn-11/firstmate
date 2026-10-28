#!/usr/bin/env bash
# Behavior tests for bin/fm-cr-revise-guard.sh.
#
# The guard runs before and after every `cr -r`. CRUX replaces a draft (PENDING)
# latest revision in place on `cr -r`, hiding the comments on it, and adds a new
# revision when the latest one is published. These tests pin the guard's exit
# codes for each reading of a CR, and its post-upload check.
#
# mcurl and the builder-mcp stdio server are stubbed so no test reaches CRUX.
# jq is the real tool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-cr-revise-guard.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-cr-revise-guard-tests)

# make_fake_mcurl <dir>: a fakebin/mcurl serving canned bodies by URL:
#   .../revisions            FAKE_REVISIONS_BODY, HTTP code FAKE_REVISIONS_HTTP_CODE (default 200)
#   .../revisions/<n>.json   FAKE_REVISION_<n>_BODY
# -w '%{http_code}' is expanded after the body, as the credential probe needs.
# A missing revision body exits 22, like curl -f on an HTTP error.
make_fake_mcurl() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/mcurl" <<'SH'
#!/usr/bin/env bash
url=; wfmt=
while [ $# -gt 0 ]; do
  case "$1" in
    -w) wfmt=$2; shift 2 ;;
    --max-time|-m|-o|-X|--data|-H) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in
  */revisions)
    body=${FAKE_REVISIONS_BODY:-}
    code=${FAKE_REVISIONS_HTTP_CODE:-200}
    ;;
  */revisions/*.json)
    n=${url##*/revisions/}; n=${n%.json}
    var="FAKE_REVISION_${n}_BODY"
    body=${!var:-}
    [ -n "$body" ] || exit 22
    code=200
    ;;
  *) exit 22 ;;
esac
printf '%s' "$body"
[ -n "$wfmt" ] && printf '%b' "${wfmt//'%{http_code}'/$code}"
exit 0
SH
  chmod +x "$fakebin/mcurl"
  printf '%s\n' "$fakebin"
}

# make_fake_fallback <dir> <body> [<revision-2-body>]: a stub builder-mcp server
# that answers the ReadInternalWebsites call with <body>, or with
# <revision-2-body> when the call reads /revisions/2, then idles until its input
# closes, as the real server does.
make_fake_fallback() {
  local dir=$1 stub="$1/fake-builder-mcp"
  printf '%s' "$2" > "$dir/fallback.body"
  printf '%s' "${3:-$2}" > "$dir/fallback-rev2.body"
  cat > "$stub" <<SH
#!/usr/bin/env bash
while IFS= read -r line; do
  case "\$line" in
    *'"id":2'*)
      body=$(printf '%q' "$dir/fallback.body")
      case "\$line" in */revisions/2*) body=$(printf '%q' "$dir/fallback-rev2.body") ;; esac
      jq -cn --rawfile t "\$body" '{result:{content:[{type:"text",text:\$t}],isError:false},jsonrpc:"2.0",id:2}'
      ;;
  esac
done
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

# revisions_json <rev>:<status> ...: a CRUX revisions list.
revisions_json() {
  local spec out='[]' entry
  for spec in "$@"; do
    entry=$(jq -cn --argjson r "${spec%%:*}" --arg s "${spec#*:}" \
      '{review_revision_summary:{status:$s, id:{review_revision_id:{revision:$r}}}}')
    out=$(printf '%s\n%s\n' "$out" "$entry" | jq -sc '.[0] + [.[1]]')
  done
  printf '%s' "$out"
}

# revision_json <rev> <post>:<type>:<author> ...: a CRUX revision body whose
# comments carry the real field layout (post id under location.comment_location).
revision_json() {
  local rev=$1 spec out='[]' entry post rest type author
  shift
  for spec in "$@"; do
    post=${spec%%:*}; rest=${spec#*:}; type=${rest%%:*}; author=${rest#*:}
    entry=$(jq -cn --argjson r "$rev" --arg p "$post" --arg t "$type" --arg a "$author" \
      '{cr_comment:{location:{comment_location:{revision:$r, post:$p, location:"TOP"}},
                    fixed:false, parent:null, content:"comment \($p) from \($a)",
                    author:{entity_id:{type:$t, id:$a}}}}')
    out=$(printf '%s\n%s\n' "$out" "$entry" | jq -sc '.[0] + [.[1]]')
  done
  jq -cn --argjson c "$out" '{revision:{cr_revision:{status:"x", comments:$c}}}'
}

# run_guard <fakebin> <fallback-bin> -- args... : run the guard hermetically.
# Remaining KEY=VAL words before "--" become the fake mcurl's environment.
run_guard() {
  local fakebin=$1 fallback=$2 envs=()
  shift 2
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -i HOME="$HOME" PATH="$fakebin:$BASE_PATH" FM_CR_FALLBACK_BIN="$fallback" FM_CR_REVISE_FALLBACK_TIMEOUT=10 \
    "${envs[@]}" bash "$GUARD" "$@"
}

new_case() {
  local dir="$TMP_ROOT/$1.$$.$RANDOM"
  mkdir -p "$dir"
  printf '%s\n%s\n' "$dir" "$(make_fake_mcurl "$dir")"
}

test_published_latest_is_safe_and_predicts_a_new_revision() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case published)
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 1:USER:smmalyal 2:USER:smmalyal)" \
    -- CR-307757603 --baseline "$dir/base.json" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "a published latest revision must be safe, got exit $rc: $out"
  assert_contains "$out" "will add revision 2" "the guard should predict a new revision"
  [ "$(jq -r .predicted_revision "$dir/base.json")" = 2 ] || fail "baseline should record predicted revision 2"
  pass "a published latest revision is safe, even with reviewer comments on it"
}

test_draft_with_only_bot_comments_is_safe_in_place() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case draft-bots)
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:PENDING)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 1:AAA:CoverlayWorker 2:AAA:MergeService)" \
    -- CR-1000001 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "a draft with only noise-list bot comments must be safe, got exit $rc: $out"
  assert_contains "$out" "replace it in place as revision 1" "the guard should predict an in-place replace"
  pass "a draft whose comments are all noise-list bots is safe to replace"
}

test_draft_with_human_comment_blocks_and_saves_it_verbatim() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case draft-human)
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:PENDING)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 1:USER:smmalyal 2:USER:smmalyal 3:AAA:CoverlayWorker)" \
    -- https://code.amazon.com/reviews/CR-307757603 --baseline "$dir/base.json" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "a draft with a human comment must block with exit 1, got $rc: $out"
  assert_contains "$out" "draft revision 1" "the block should name the revision"
  assert_contains "$out" "2 reviewer comment(s)" "the block should count the human comments"
  assert_contains "$out" "smmalyal x2" "the block should name each author"
  assert_not_contains "$out" "CoverlayWorker" "a noise-list bot is not a blocking comment"
  [ "$(jq -r '.blocking_comments[0].content' "$dir/base.json")" = "comment 1 from smmalyal" ] \
    || fail "the baseline should hold the blocking comments verbatim"
  pass "a draft carrying a human comment blocks, naming the revision, count and authors"
}

test_draft_above_a_published_revision_with_aaa_reviewer_blocks() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case draft-aaa)
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN 2:PENDING)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 1:USER:smmalyal)" \
    FAKE_REVISION_2_BODY="$(revision_json 2 1:AAA:AutoSDE)" \
    -- CR-1000002 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "an AAA reviewer comment on a draft latest revision must block, got $rc: $out"
  assert_contains "$out" "draft revision 2" "only the draft latest revision is at risk"
  assert_contains "$out" "AutoSDE x1" "the AAA reviewer is named"
  assert_not_contains "$out" "smmalyal" "comments on the published revision are not at risk"
  pass "a draft above a published revision blocks on its own reviewer comments only"
}

test_unreadable_cr_is_cannot_assess_never_safe() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case unreadable)
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_HTTP_CODE=401 FAKE_REVISIONS_BODY=denied \
    -- CR-1000003 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "an unreadable CR with no fallback must exit 3, got $rc: $out"
  assert_contains "$out" "cannot-assess" "the guard should say it cannot assess"
  assert_contains "$out" "Do not run cr -r" "the guard should tell the crew to stop"
  rc=0
  out=$(run_guard "$fakebin" "$(make_fake_fallback "$dir" 'not json')" \
    FAKE_REVISIONS_HTTP_CODE=401 FAKE_REVISIONS_BODY=denied \
    -- CR-1000003 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a broken fallback must still exit 3, got $rc: $out"
  rc=0
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:PENDING)" \
    -- CR-1000003 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a revision body that cannot be fetched must exit 3, got $rc: $out"
  pass "an unreadable CR exits 3 (cannot assess), never 0"
}

test_fallback_reads_draft_comments_when_mcurl_is_down() {
  local dir fakebin stub out rc=0 body
  { read -r dir; read -r fakebin; } < <(new_case fallback)
  body=$(jq -cn '{content:{crId:"CR-1000004", revision:2, latestRevision:2,
    revisionSummary:{status:"PENDING"},
    allComments:[{revision:1, post:1, author:"smmalyal", fixed:false, location:"TOP", content:"on the published revision"},
                 {revision:2, post:1, author:"smmalyal", fixed:true, location:"TOP", content:"on the draft"},
                 {revision:2, post:2, author:"CoverlayWorker", fixed:true, location:"TOP", content:"coverage"}]}}')
  stub=$(make_fake_fallback "$dir" "$body")
  out=$(run_guard "$fakebin" "$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 FAKE_REVISIONS_BODY=denied \
    -- CR-1000004 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "the fallback should see the human comment on the draft and block, got $rc: $out"
  assert_contains "$out" "draft revision 2" "the fallback reading should name the draft revision"
  assert_contains "$out" "1 reviewer comment(s)" "a fixed human comment still counts, and the bot does not"
  pass "with mcurl down, the builder-mcp fallback reading blocks on a draft's human comment"
}

test_post_upload_confirms_the_predicted_new_revision() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case after-ok)
  run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 1:USER:smmalyal)" \
    -- CR-1000005 --baseline "$dir/base.json" >/dev/null 2>&1 || fail "pre-upload check should pass"
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN 2:PENDING)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 1:USER:smmalyal)" \
    FAKE_REVISION_2_BODY="$(revision_json 2)" \
    -- CR-1000005 --after "$dir/base.json" --uploaded 2 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "a new revision with every earlier comment intact must confirm, got $rc: $out"
  assert_contains "$out" "confirmed" "the post-upload check should confirm"
  pass "the post-upload check confirms a new revision that kept every earlier comment"
}

test_post_upload_flags_wrong_revision_and_vanished_comments() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case after-bad)
  run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 1:USER:smmalyal 2:USER:smmalyal)" \
    -- CR-1000006 --baseline "$dir/base.json" >/dev/null 2>&1 || fail "pre-upload check should pass"
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 2:USER:smmalyal)" \
    -- CR-1000006 --after "$dir/base.json" --uploaded 1 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "a replaced revision must exit 4, got $rc: $out"
  assert_contains "$out" "cr printed revision 1, the guard predicted revision 2" "the revision mismatch is named"
  assert_contains "$out" "comment 1:1 by smmalyal is gone" "the vanished comment is named"
  assert_not_contains "$out" "comment 1:2" "a surviving comment is not reported"
  pass "the post-upload check flags an unexpected revision number and a vanished comment"
}

test_post_upload_ignores_the_draft_it_replaced() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case after-inplace)
  run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:PENDING)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 1:AAA:CoverlayWorker)" \
    -- CR-1000007 --baseline "$dir/base.json" >/dev/null 2>&1 || fail "pre-upload check should pass"
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:PENDING)" \
    FAKE_REVISION_1_BODY="$(revision_json 1)" \
    -- CR-1000007 --after "$dir/base.json" --uploaded 1 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "a predicted in-place replace that dropped only a bot comment must confirm, got $rc: $out"
  pass "the post-upload check expects the replaced draft's bot comments to go"
}

test_fallback_comments_without_ids_cannot_be_assessed() {
  # A comment with no revision or post id cannot be placed on or off the draft,
  # so the guard cannot call the upload safe.
  local dir fakebin stub out rc=0 body
  { read -r dir; read -r fakebin; } < <(new_case fallback-no-ids)
  body=$(jq -cn '{content:{crId:"CR-1000010", revision:2, latestRevision:2,
    revisionSummary:{status:"PENDING"},
    allComments:[{author:"smmalyal", created_at:"2026-09-29T18:53:24Z", fixed:false, location:"TOP", content:"human"},
                 {author:"CoverlayWorker", created_at:"2026-09-29T19:25:21Z", fixed:true, location:"TOP", content:"coverage"}]}}')
  stub=$(make_fake_fallback "$dir" "$body")
  out=$(run_guard "$fakebin" "$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 FAKE_REVISIONS_BODY=denied \
    -- CR-1000010 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "fallback comments without ids must exit 3, got $rc: $out"
  assert_contains "$out" "no revision or post id" "the reason should name the missing ids"
  rc=0
  body=$(jq -cn '{content:{crId:"CR-1000010", revision:2, latestRevision:2,
    revisionSummary:{status:"PENDING"},
    allComments:[{revision:2, author:"smmalyal", fixed:false, location:"TOP", content:"human"}]}}')
  stub=$(make_fake_fallback "$dir" "$body")
  out=$(run_guard "$fakebin" "$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 FAKE_REVISIONS_BODY=denied \
    -- CR-1000010 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a fallback comment with a revision but no post id must exit 3, got $rc: $out"
  pass "fallback comments with no revision or post id cannot be assessed"
}

test_unknown_revision_status_cannot_be_assessed() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case unknown-status)
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:DRAFTING)" \
    FAKE_REVISION_1_BODY="$(revision_json 1 1:USER:smmalyal)" \
    -- CR-1000011 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "an unknown revision status must exit 3, got $rc: $out"
  assert_contains "$out" "DRAFTING" "the reason should name the status"
  pass "an unknown revision status is cannot-assess, never treated as published"
}

test_post_upload_refuses_a_baseline_from_another_cr() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case after-other-cr)
  run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN)" \
    FAKE_REVISION_1_BODY="$(revision_json 1)" \
    -- CR-1000012 --baseline "$dir/base.json" >/dev/null 2>&1 || fail "pre-upload check should pass"
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN 2:PENDING)" \
    FAKE_REVISION_1_BODY="$(revision_json 1)" \
    FAKE_REVISION_2_BODY="$(revision_json 2)" \
    -- CR-1000013 --after "$dir/base.json" --uploaded 2 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "a baseline from another CR must exit 2, got $rc: $out"
  assert_contains "$out" "was recorded for https://code.amazon.com/reviews/CR-1000012" "the error should name the baseline's CR"
  pass "the post-upload check refuses a baseline recorded for another CR"
}

test_terminal_or_empty_status_cannot_be_assessed() {
  local dir fakebin out rc status
  { read -r dir; read -r fakebin; } < <(new_case terminal)
  for status in SHIPPED ""; do
    rc=0
    out=$(run_guard "$fakebin" "$dir/none" \
      FAKE_REVISIONS_BODY="$(revisions_json "1:$status")" \
      FAKE_REVISION_1_BODY="$(revision_json 1)" \
      -- CR-1000014 2>&1) || rc=$?
    [ "$rc" = 3 ] || fail "latest status '$status' must exit 3, got $rc: $out"
  done
  pass "a terminal or empty latest status is cannot-assess"
}

test_fallback_rereads_the_latest_revision() {
  # The fallback's first read can land on an older revision. The guard then
  # reads the latest revision explicitly before judging it.
  local dir fakebin stub out rc=0 first latest
  { read -r dir; read -r fakebin; } < <(new_case fallback-reread)
  first=$(jq -cn '{content:{revision:1, latestRevision:2, revisionSummary:{status:"OPEN"}, allComments:[]}}')
  latest=$(jq -cn '{content:{revision:2, latestRevision:2, revisionSummary:{status:"PENDING"},
    allComments:[{revision:2, post:1, author:"smmalyal", fixed:false, location:"TOP", content:"on the draft"}]}}')
  stub=$(make_fake_fallback "$dir" "$first" "$latest")
  out=$(run_guard "$fakebin" "$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 FAKE_REVISIONS_BODY=denied \
    -- CR-1000015 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "the re-read latest draft carries a human comment and must block, got $rc: $out"
  assert_contains "$out" "draft revision 2" "the verdict should be about the latest revision"
  pass "the fallback re-reads the latest revision when its first read is older"
}

test_fallback_reread_returning_another_revision_cannot_be_assessed() {
  local dir fakebin stub out rc=0 body
  { read -r dir; read -r fakebin; } < <(new_case fallback-stale-reread)
  body=$(jq -cn '{content:{revision:1, latestRevision:2, revisionSummary:{status:"OPEN"},
    allComments:[{revision:2, post:1, author:"smmalyal", fixed:false, location:"TOP", content:"on the draft"}]}}')
  stub=$(make_fake_fallback "$dir" "$body")
  out=$(run_guard "$fakebin" "$stub" \
    FAKE_REVISIONS_HTTP_CODE=403 FAKE_REVISIONS_BODY=denied \
    -- CR-1000018 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a re-read that still returns revision 1 must exit 3, got $rc: $out"
  assert_contains "$out" "asked for revision 2 and got revision 1" "the reason should name both revisions"
  pass "a fallback re-read that returns another revision cannot be assessed"
}

test_post_upload_flags_crux_latest_differing_from_the_upload() {
  local dir fakebin out rc=0
  { read -r dir; read -r fakebin; } < <(new_case after-latest)
  run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN)" \
    FAKE_REVISION_1_BODY="$(revision_json 1)" \
    -- CR-1000016 --baseline "$dir/base.json" >/dev/null 2>&1 || fail "pre-upload check should pass"
  out=$(run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN)" \
    FAKE_REVISION_1_BODY="$(revision_json 1)" \
    -- CR-1000016 --after "$dir/base.json" --uploaded 2 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "CRUX still at revision 1 after an upload printed 2 must exit 4, got $rc: $out"
  assert_contains "$out" "CRUX's latest revision is 1, not the uploaded revision 2" "the mismatch is named"
  pass "the post-upload check flags CRUX's latest revision differing from the upload"
}

test_baseline_errors_exit_2() {
  local dir fakebin rc=0
  { read -r dir; read -r fakebin; } < <(new_case baseline-errors)
  printf '{"not":"a baseline"}' > "$dir/other.json"
  run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN)" FAKE_REVISION_1_BODY="$(revision_json 1)" \
    -- CR-1000017 --after "$dir/other.json" --uploaded 2 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "a file that is not a guard baseline must exit 2, got $rc"
  rc=0
  touch "$dir/a-file"
  run_guard "$fakebin" "$dir/none" \
    FAKE_REVISIONS_BODY="$(revisions_json 1:OPEN)" FAKE_REVISION_1_BODY="$(revision_json 1)" \
    -- CR-1000017 --baseline "$dir/a-file/base.json" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "an unwritable baseline path must exit 2, got $rc"
  pass "a non-baseline file and an unwritable baseline path exit 2"
}

test_usage_errors_exit_2() {
  local rc=0
  bash "$GUARD" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "no arguments should exit 2, got $rc"
  rc=0
  bash "$GUARD" not-a-cr >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "a non-CR argument should exit 2, got $rc"
  rc=0
  bash "$GUARD" CR-1 --after /nonexistent >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "--after without --uploaded should exit 2, got $rc"
  rc=0
  bash "$GUARD" CR-1 --uploaded 2 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "--uploaded without --after should exit 2, got $rc"
  rc=0
  bash "$GUARD" CR-1 --after /nonexistent --uploaded 2 --baseline /tmp/x >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "--after with --baseline should exit 2, got $rc"
  pass "usage errors exit 2"
}

test_published_latest_is_safe_and_predicts_a_new_revision
test_draft_with_only_bot_comments_is_safe_in_place
test_draft_with_human_comment_blocks_and_saves_it_verbatim
test_draft_above_a_published_revision_with_aaa_reviewer_blocks
test_unreadable_cr_is_cannot_assess_never_safe
test_fallback_reads_draft_comments_when_mcurl_is_down
test_post_upload_confirms_the_predicted_new_revision
test_post_upload_flags_wrong_revision_and_vanished_comments
test_post_upload_ignores_the_draft_it_replaced
test_fallback_comments_without_ids_cannot_be_assessed
test_unknown_revision_status_cannot_be_assessed
test_post_upload_refuses_a_baseline_from_another_cr
test_terminal_or_empty_status_cannot_be_assessed
test_fallback_rereads_the_latest_revision
test_fallback_reread_returning_another_revision_cannot_be_assessed
test_post_upload_flags_crux_latest_differing_from_the_upload
test_baseline_errors_exit_2
test_usage_errors_exit_2
