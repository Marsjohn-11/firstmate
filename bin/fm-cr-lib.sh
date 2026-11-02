#!/usr/bin/env bash
# fm-cr-lib.sh - the one CRUX (code.amazon.com) read path shared by the CR tools.
#
# Sourced, never executed. bin/fm-cr-poll.sh, bin/fm-cr-analyzers.sh,
# bin/fm-cr-revise-guard.sh, and bin/fm-teardown.sh read a code review through
# these helpers, so every tool fetches, classifies, and parses a CR the same way.
#
#   fm_cr_ref_parse <CR-<digits>|canonical URL>
#       Sets FM_CR_URL and FM_CR_ID; bin/fm-delivery-target-lib.sh owns the
#       canonical URL shape.
#   fm_cr_mcurl_get <url>          bounded fetch; body on success, silent failure
#   fm_cr_mcurl_probe <url>        line 1 ok|posture|denied|unreachable, then the body
#   fm_cr_revision_json <cr> <n>   revision <n>'s JSON body
#   fm_cr_comment_revisions <cr>   published revisions plus a draft (PENDING) latest
#   fm_cr_fetch_comments <cr>      normalized comments across those revisions
#   FM_CR_JQ_AUTHOR_DEFS           jq defs deciding which authors count as reviewers
#   fm_cr_unresolved_comment_ids <revision-json>   sorted unresolved thread ids
#   fm_cr_snapshot_id_from_revision <revision-json>
#   fm_cr_missing_destination_from_snapshot <snapshot-json>
#   fm_cr_missing_destination <cr>  packages the CR would ship with no destination
#   fm_cr_tip_commits_from_snapshot <snapshot-json>  each package's uploaded tip
#   fm_cr_landing_read <cr>        latest status and uploaded tips, either path
#   fm_cr_analyzers_array / fm_cr_analyzer_gating_total / fm_cr_analyzer_lines
#   fm_cr_merge_failure <revision-or-fallback-json>  a CRUX merge failure on
#                                  the latest revision, or nothing
#   fm_cr_merge_failure_reason <merge-failure-line>  that failure in plain words
#   fm_cr_fallback_*               the builder-mcp credential path
#
# Failure returns, so callers map them to their own diagnostics:
#   3  the fetch failed (auth, network, timeout, server error)
#   4  jq could not parse the body
#   5  no qualifying revision exists yet
#   6  the revision's diff source is not a WSNAP snapshot, so it cannot be assessed
#   7  the body carries no analyzers array
#
# Two credential paths reach CRUX and fail independently. mcurl uses the Midway
# cookie and also fails on an Amazon Enterprise Access (AEA) posture rejection,
# a 403 that `mwinit` does not clear. builder-mcp uses its own credentials and
# keeps reading through that posture failure, so it is a real fallback.
# fm_cr_mcurl_probe names the mode it saw, because posture means "route around
# it" while expiry means "run mwinit".
#
# Dependencies: mcurl and jq; builder-mcp through bin/fm-builder-mcp-call.sh for
# the fallback. bash 3.2 compatible.

# shellcheck source=bin/fm-delivery-target-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-delivery-target-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"

# fm_cr_ref_parse <input>: accept a bare CR-<digits> or the canonical review URL.
fm_cr_ref_parse() {
  local input=${1-}
  case "$input" in
    CR-*) fm_cr_url_parse "https://code.amazon.com/reviews/$input" ;;
    *) fm_cr_url_parse "$input" ;;
  esac
}

# fm_cr_mcurl_get <url>: refuses anything slower than FM_CR_MAX_TIME (10s), so
# a hung connection cannot stall a watcher poll.
fm_cr_mcurl_get() {
  mcurl -fsS --max-time "${FM_CR_MAX_TIME:-10}" "$1" 2>/dev/null
}

fm_cr_revision_json() {
  fm_cr_mcurl_get "https://code.amazon.com/reviews/$1/revisions/$2.json" || return 3
}

# fm_cr_comment_revisions <cr>: every revision whose comments count, ascending.
# A reviewer can comment on a draft, and `cr -r` replaces a draft in place, so
# a PENDING latest revision is read too.
fm_cr_comment_revisions() {
  local cr=$1 revs list
  revs=$(fm_cr_mcurl_get "https://code.amazon.com/reviews/$cr/revisions") || return 3
  list=$(printf '%s' "$revs" | jq -r '
    [ .[].review_revision_summary | {r: .id.review_revision_id.revision, s: .status} ]
    | (max_by(.r).r) as $latest
    | [ .[] | select(.s != "PENDING" or .r == $latest) | .r ] | sort | .[]' 2>/dev/null) || return 4
  [ -n "$list" ] || return 5
  printf '%s\n' "$list"
}

# fm_cr_fetch_comments <cr>: one JSON array of
#   {revision, post_id, author, author_type, parent, fixed, location, content}
# CRUX numbers posts per revision, so a comment is keyed by (revision, post_id).
# location renders "TOP" for a whole-CR comment. A v4 location
#   v4:<package>:<path>:<old-start>:<new-start>:<old-end>:<new-end>:<descriptor>
# renders "<path>:<new-start>", or "<path>" with no new-side line, with a
# "<package>/" prefix when the revision spans more than one package.
fm_cr_fetch_comments() {
  local cr=$1 revs rev data all merged packages
  revs=$(fm_cr_comment_revisions "$cr") || return $?
  all='[]'
  data='{}'
  for rev in $revs; do
    data=$(fm_cr_revision_json "$cr" "$rev") || return 3
    merged=$(printf '%s' "$data" | jq -c --argjson rev "$rev" '[.revision.cr_revision.comments[]?.cr_comment | .location.comment_location.revision //= $rev]' 2>/dev/null) || return 4
    all=$(printf '%s\n%s\n' "$all" "$merged" | jq -sc '(.[0] + .[1]) | group_by([.location.comment_location.revision, .location.comment_location.post]) | map(last)' 2>/dev/null) || return 4
  done
  packages=$(printf '%s' "$data" | jq '.revision.cr_revision.packages // [] | length' 2>/dev/null) || return 4
  printf '%s' "$all" | jq -c --argjson packages "$packages" '
    [ .[] | {
        revision: .location.comment_location.revision,
        post_id: .location.comment_location.post,
        author: .author.entity_id.id,
        author_type: .author.entity_id.type,
        parent: .parent,
        fixed: .fixed,
        location: (.location.comment_location.location |
          if . == null or . == "TOP" or . == "v4:TOP::::::" then "TOP"
          else (split(":") |
            if .[0] == "v4" and length >= 5 then
              (if .[2] == "" then .[1] elif $packages > 1 then "\(.[1])/\(.[2])" else .[2] end)
              + (if .[4] == "" then "" else ":\(.[4])" end)
            elif length >= 5 then "\(.[1]):\(.[4])"
            else join(":") end)
          end),
        content: (.content // "")
      } ]
  ' 2>/dev/null || return 4
}

# Reviewer-author classification shared by every comment filter. CRUX posts
# every service principal as author type AAA, including the ones that post real
# findings (AutoSDE, KrakenReview), so AAA counts like USER unless the author is
# a pure status poster: a coverage, build, dependency-scan, or merge notice, or
# any *Worker / *Bot.
# shellcheck disable=SC2016  # jq expands its own variables
FM_CR_JQ_AUTHOR_DEFS='
  def fm_noise_author:
    test("^(CoverlayWorker|CoverageBot|GK-CRUX-Analyzer|BuildGuardian|MergeService|ChangeGuardianCodeAnalyzer)$|Worker$|Bot$"; "i");
  def fm_reviewer_author(type; id):
    (type) as $t | (id // "") as $i
    | $t == "USER" or ($t == "AAA" and ($i | fm_noise_author | not));
'

# fm_cr_unresolved_comment_ids <revision-json>: unresolved reviewer threads,
# keyed by thread-root post id, sorted and space-separated. The id lives at
# .location.comment_location.post; a CRUX comment carries no .id field. A reply
# folds onto its root, so a thread whose root is fixed while a reply still
# objects stays counted, and is counted once.
fm_cr_unresolved_comment_ids() {
  printf '%s' "$1" | jq -r "$FM_CR_JQ_AUTHOR_DEFS"'
    [ .revision.cr_revision.comments[]?.cr_comment ] as $all
    | ( [ $all[] | select(.location.comment_location.post != null)
          | { key: (.location.comment_location.post | tostring), value: . } ] | from_entries
      ) as $by_post
    | [ $all[]
        | select(.fixed == false and fm_reviewer_author(.author.entity_id.type; .author.entity_id.id))
        | ( if .parent == null then .location.comment_location.post
            else ( ($by_post[.parent | tostring]) as $p
                   | if $p == null then .location.comment_location.post
                     elif $p.parent == null then $p.location.comment_location.post
                     else ( ($by_post[$p.parent | tostring]) as $g
                            | if $g == null then $p.location.comment_location.post
                              else $g.location.comment_location.post end )
                     end )
            end )
        | select(. != null) | tostring ]
    | unique | join(" ")
  ' 2>/dev/null || return 4
}

# fm_cr_body_is_posture <body>: 0 for a Midway/AEA posture interstitial. This is
# a body test because a dead cookie returns the same 403.
fm_cr_body_is_posture() {
  printf '%s' "${1:-}" \
    | grep -qiE 'id="?posture[_-]error|Midway Authentication Portal|Amazon Enterprise Access|must use AEA'
}

# fm_cr_mcurl_probe <url>: fetch without -f, so a 403 body survives to tell
# posture from expiry. The status code follows a literal marker rather than a
# newline, because a body can end in newlines. The marker must not start with
# '@', which curl reads as a format file name.
fm_cr_mcurl_probe() {
  local url=$1 raw body code rc
  raw=$(mcurl -sS -w 'FMCODE:%{http_code}' --max-time "${FM_CR_MAX_TIME:-10}" "$url" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'unreachable\n'
    return 0
  fi
  case "$raw" in
    *FMCODE:*)
      code=${raw##*FMCODE:}
      body=${raw%FMCODE:*}
      ;;
    *)
      body=$raw
      code=
      ;;
  esac
  if [ -z "$code" ]; then
    if fm_cr_body_is_posture "$body"; then printf 'posture\n'; return 0; fi
    if [ -n "$body" ]; then printf 'ok\n%s' "$body"; return 0; fi
    printf 'unreachable\n'
    return 0
  fi
  case "$code" in
    2*)
      # A portal redirect can serve the posture page with a 200.
      if fm_cr_body_is_posture "$body"; then printf 'posture\n'; return 0; fi
      printf 'ok\n%s' "$body"
      ;;
    401|403)
      if fm_cr_body_is_posture "$body"; then printf 'posture\n'; else printf 'denied\n'; fi
      ;;
    *) printf 'unreachable\n' ;;
  esac
}

# The builder-mcp fallback. bin/fm-builder-mcp-call.sh owns the stdio session;
# this bounds it at FM_CR_FALLBACK_TIMEOUT (20s). FM_CR_FALLBACK_BIN overrides
# the server path.
fm_cr_fallback_bin() {
  if [ -n "${FM_CR_FALLBACK_BIN:-}" ]; then
    printf '%s' "$FM_CR_FALLBACK_BIN"
    return 0
  fi
  command -v builder-mcp 2>/dev/null || printf '%s' "$HOME/.toolbox/bin/builder-mcp"
}

fm_cr_fallback_available() {
  local bin
  bin=$(fm_cr_fallback_bin) || return 1
  [ -n "$bin" ] && [ -x "$bin" ]
}

# fm_cr_mcp_read <url>: echo the ReadInternalWebsites text for <url>, or return 3.
fm_cr_mcp_read() {
  local url=$1 bin secs args text
  bin=$(fm_cr_fallback_bin) || return 3
  [ -n "$bin" ] && [ -x "$bin" ] || return 3
  secs=${FM_CR_FALLBACK_TIMEOUT:-20}
  case "$secs" in ''|0*|*[!0-9]*) secs=20 ;; esac
  args=$(jq -cn --arg url "$url" '{inputs: [$url]}') || return 3
  text=$(FM_BUILDER_MCP_BIN="$bin" fm_run_timed "$secs" \
    "$(dirname "${BASH_SOURCE[0]}")/fm-builder-mcp-call.sh" ReadInternalWebsites "$args" 2>/dev/null) || return 3
  [ -n "$text" ] || return 3
  printf '%s' "$text"
}

# fm_cr_fallback_cr_json <cr> [rev]: the builder-mcp view of a CR, with status,
# snapshot, and analyzers. FM_CR_FALLBACK_COMMENTS=1 adds every comment, which
# costs several times longer, so only callers with a longer budget ask for it.
fm_cr_fallback_cr_json() {
  local cr=$1 rev=${2:-} url out
  url="https://code.amazon.com/reviews/$cr"
  [ -z "$rev" ] || url="$url/revisions/$rev"
  url="$url?diffConfig=none"
  case "${FM_CR_FALLBACK_COMMENTS:-0}" in
    1|true|yes|on) url="$url&include-all-comments=true" ;;
  esac
  out=$(fm_cr_mcp_read "$url") || return 3
  printf '%s' "$out" | jq -e '.content | type == "object"' >/dev/null 2>&1 || return 3
  printf '%s' "$out"
}

# fm_cr_fallback_has_comments <fallback-json>: tells "no unresolved comments"
# apart from "comments were not fetched".
fm_cr_fallback_has_comments() {
  printf '%s' "$1" | jq -e '.content.allComments | type == "array"' >/dev/null 2>&1
}

fm_cr_fallback_status() {
  printf '%s' "$1" | jq -r '.content.revisionSummary.status // empty' 2>/dev/null || return 4
}

# fm_cr_fallback_comment_ids <fallback-json>: the fallback carries no post id,
# so each unresolved comment is keyed by author, creation time, and location.
# Those keys are stable but not comparable with mcurl post ids, which is why
# the poll records which path produced its set.
fm_cr_fallback_comment_ids() {
  printf '%s' "$1" | jq -r "$FM_CR_JQ_AUTHOR_DEFS"'
    [ .content.allComments[]?
      | select((.fixed // false) == false)
      | select((.author // "") | fm_noise_author | not)
      | "\(.author // "?")@\(.created_at // "?")#\(.location // "TOP")" ]
    | sort | join(" ")
  ' 2>/dev/null || return 4
}

# Snapshot helpers. A revision's diff_source names a WSNAP snapshot with one
# entry per package; each branch records local_branch, gitfarm_branch (the
# destination), and tip_commit (the uploaded commit). A branch with no upstream
# uploads with an empty gitfarm_branch, which CRUX reports as "no destination
# branch" and cannot merge. The mcurl snapshot is {snapshot:...}; the fallback
# inlines it at .content.snapshotDetails.
# shellcheck disable=SC2016  # jq expands its own variables
FM_CR_JQ_SNAPSHOT_DEFS='
  def fm_snapshot_packages:
    (.snapshot // .content.snapshotDetails.snapshot // {}) | .content[]?.content;
'

fm_cr_snapshot_id_from_revision() {
  local revjson=$1 type id
  type=$(printf '%s' "$revjson" | jq -r '.revision.cr_revision.diff_source.diff_source.type // empty' 2>/dev/null) || return 4
  [ "$type" = WSNAP ] || return 6
  id=$(printf '%s' "$revjson" | jq -r '.revision.cr_revision.diff_source.diff_source.id // empty' 2>/dev/null) || return 4
  [ -n "$id" ] || return 6
  printf '%s' "$id"
}

# fm_cr_missing_destination_from_snapshot <snapshot-or-fallback-json>: one
# package name per line that has no destination branch.
fm_cr_missing_destination_from_snapshot() {
  printf '%s' "$1" | jq -r "$FM_CR_JQ_SNAPSHOT_DEFS"'
    [ fm_snapshot_packages
      | select(
          ((.branches // []) | length) == 0
          or any((.branches // [])[]?.branch; (.gitfarm_branch // "") == "")
        )
      | (.package_name // empty) ]
    | unique | .[]
  ' 2>/dev/null || return 4
}

fm_cr_fallback_missing_destination() {
  fm_cr_missing_destination_from_snapshot "$1"
}

# fm_cr_tip_commits_from_snapshot <snapshot-or-fallback-json>: each uploaded
# tip commit, one per line.
fm_cr_tip_commits_from_snapshot() {
  printf '%s' "$1" | jq -r "$FM_CR_JQ_SNAPSHOT_DEFS"'
    [ fm_snapshot_packages | (.branches // [])[]?.branch.tip_commit // empty
      | select(test("^[0-9a-f]{40}$")) ] | unique | .[]
  ' 2>/dev/null || return 4
}

# fm_cr_latest_revision_any <cr>: the highest revision of any status, so a draft
# whose only revision is PENDING is assessed.
fm_cr_latest_revision_any() {
  local revs rev
  revs=$(fm_cr_mcurl_get "https://code.amazon.com/reviews/$1/revisions") || return 3
  rev=$(printf '%s' "$revs" | jq -r 'max_by(.review_revision_summary.id.review_revision_id.revision) | .review_revision_summary.id.review_revision_id.revision // empty' 2>/dev/null) || return 4
  [ -n "$rev" ] || return 5
  printf '%s' "$rev"
}

# fm_cr_latest_snapshot <cr>: the latest revision's snapshot body over mcurl.
fm_cr_latest_snapshot() {
  local cr=$1 rev revjson snap_id
  rev=$(fm_cr_latest_revision_any "$cr") || return $?
  revjson=$(fm_cr_revision_json "$cr" "$rev") || return 3
  snap_id=$(fm_cr_snapshot_id_from_revision "$revjson") || return $?
  fm_cr_mcurl_get "https://code.amazon.com/snapshots/$snap_id.json" || return 3
}

# fm_cr_missing_destination <cr>: packages the CR would ship with no
# destination branch, one per line; empty output means every package has one.
fm_cr_missing_destination() {
  local snap
  snap=$(fm_cr_latest_snapshot "$1") || return $?
  fm_cr_missing_destination_from_snapshot "$snap"
}

# fm_cr_landing_read <cr>: line 1 is the latest revision's status, and each
# further line is an uploaded tip commit. mcurl first, then builder-mcp.
# Returns 3 when neither path yields a status.
fm_cr_landing_read() {
  local cr=$1 rev revjson status snap_id snap fb
  if rev=$(fm_cr_latest_revision_any "$cr") \
    && revjson=$(fm_cr_revision_json "$cr" "$rev") \
    && status=$(printf '%s' "$revjson" | jq -r '.revision.cr_revision.status // empty' 2>/dev/null) \
    && [ -n "$status" ]; then
    printf '%s\n' "$status"
    if snap_id=$(fm_cr_snapshot_id_from_revision "$revjson") \
      && snap=$(fm_cr_mcurl_get "https://code.amazon.com/snapshots/$snap_id.json"); then
      fm_cr_tip_commits_from_snapshot "$snap" || true
    fi
    return 0
  fi
  fm_cr_fallback_available || return 3
  fb=$(fm_cr_fallback_cr_json "$cr") || return 3
  status=$(fm_cr_fallback_status "$fb") || return 3
  [ -n "$status" ] || return 3
  printf '%s\n' "$status"
  fm_cr_tip_commits_from_snapshot "$fb" || true
}

# Analyzer helpers. Each entry carries partner_id, status, status_message, and
# pass_required_for. A non-empty pass_required_for (Merge and/or Auto-Publish)
# makes the analyzer merge-gating, so it must be Pass; an empty one blocks
# nothing and is advisory. Any status other than Pass is not green, so a gating
# analyzer that is still running is not ready. mcurl revision JSON carries the
# array at top level, the fallback under .content.

fm_cr_analyzers_array() {
  local arr
  arr=$(printf '%s' "$1" | jq -c '(.analyzers // .content.analyzers // empty) | select(type == "array")' 2>/dev/null) || return 4
  [ -n "$arr" ] || return 7
  printf '%s' "$arr"
}

fm_cr_analyzer_gating_total() {
  printf '%s' "$1" | jq -r '[ .[] | select((.pass_required_for // []) | length > 0) ] | length' 2>/dev/null || return 4
}

# fm_cr_analyzer_lines <analyzers-array>: one TSV line per analyzer,
#   <class>\t<partner_id>\t<status>\t<status_message>
# where class is blocking or advisory for a non-Pass analyzer, and gating-pass
# or advisory-pass for a Pass. Control characters in the message become spaces.
fm_cr_analyzer_lines() {
  printf '%s' "$1" | jq -r '
    .[]
    | ((.pass_required_for // []) | length > 0) as $gating
    | ((.status // "") == "Pass") as $pass
    | [ (if $pass then (if $gating then "gating-pass" else "advisory-pass" end)
         elif $gating then "blocking" else "advisory" end),
        (.partner_id // "?"),
        (.status // "?"),
        ((.status_message // "") | gsub("[\r\n\t]+"; " ")) ]
    | @tsv
  ' 2>/dev/null || return 4
}

# Merge-failure helpers. CRUX exposes no merge-status field. The review page's
# "Merge failed. Package <X> had merge conflicts." banner is built from a
# MergeService TOP comment on the latest revision, and a failed auto-merge
# clears the revision's auto_merge. A failure counts only while the review is
# unmerged and the comment sits on the latest revision, because a new revision
# supersedes it. Both credential paths carry the revision at
# .revision.cr_revision (mcurl) or .content.revisionDetails.revision.cr_revision
# (builder-mcp).
#
# fm_cr_merge_failure <revision-or-fallback-json>: nothing when no failure
# applies, else one TSV line
#   <conflict|failed>\t<packages, space-separated, or ->\t<cleared|armed>\t<title>
# where cleared means auto-merge was turned off, so CRUX will not retry. Every
# field is non-empty, because a shell read collapses adjacent tabs.
fm_cr_merge_failure() {
  printf '%s' "$1" | jq -r '
    def fail_title: test("CRUX ((Auto-)?Merge|(AutoVerify|FastTrack) merge) ((partially )?failed|could not run)"; "i");
    def banner_re: "Merge failed\\.\\s+Packages?\\s+(?<pkgs>.+?)\\s+had merge conflicts";
    def conflict_rows:
      [ split("\n")[] | split("|") | select(length >= 3)
        | select((.[0] | gsub("\\s"; "")) | test("^[0-9]+$"))
        | select(.[length - 1] | test("Merge conflict detected"; "i"))
        | (.[1] | gsub("^\\s+|\\s+$"; "")) as $cell
        | (($cell | capture("^\\[(?<n>[^\\]]+)\\]").n) // $cell) ];
    def banner_pkgs:
      [ capture(banner_re).pkgs | gsub(",|\\band\\b"; " ") | splits("\\s+") | select(length > 0) ];
    (.revision.cr_revision // .content.revisionDetails.revision.cr_revision // {}) as $r
    | ($r.status // .content.revisionSummary.status // "") as $status
    | ($r.id.review_revision_id.revision // .content.revisionSummary.id.review_revision_id.revision) as $latest
    | select($status | test("^(SHIPPED|MERGED|CANCELED|ABANDONED|CLOSED|WITHDRAWN)$") | not)
    | [ $r.comments[]?.cr_comment
        | select(.author.entity_id.id == "MergeService")
        | select($latest == null or ((.location.comment_location.revision // $latest) == $latest))
        | select((.content // "") | (fail_title or test(banner_re))) ]
      as $fails
    | [ $r | walk(if type == "object" then del(.comments) else . end)
        | .. | strings | select(test(banner_re)) ] as $banners
    | select(($fails | length) > 0 or ($banners | length) > 0)
    | ($fails | sort_by(.created_at // "") | last) as $c
    | (($c.content // "") | conflict_rows + banner_pkgs) as $from_comment
    | ([ $banners[] | banner_pkgs[] ]) as $from_banner
    | ($from_comment + $from_banner | unique) as $pkgs
    | (if ($pkgs | length) > 0 or (($c.content // "") | test("Merge conflict detected|had merge conflicts"; "i"))
       then "conflict" else "failed" end) as $kind
    | (if ($r.auto_merge.auto_merge_state // null) == null then "cleared" else "armed" end) as $am
    | ((($c.content // "") | (split("\n")[0] // "") | gsub("^[#\\s]+|[^ -~]"; "") | gsub("^\\s+|\\s+$"; ""))
       | if . == "" then "Merge failed" else . end) as $title
    | [ $kind, (if ($pkgs | length) > 0 then $pkgs | join(" ") else "-" end), $am, $title ] | @tsv
  ' 2>/dev/null || return 4
}

# fm_cr_merge_failure_reason <merge-failure-line>: one plain-English reason,
# shared by every tool that reports the failure.
fm_cr_merge_failure_reason() {
  local kind pkgs auto title reason
  IFS="$(printf '\t')" read -r kind pkgs auto title <<EOF
$1
EOF
  [ "$pkgs" != - ] || pkgs=
  case "$kind" in
    conflict) reason="conflict - ${pkgs:+Package $pkgs }had merge conflicts ($title); rebase onto the destination branch and post a new revision" ;;
    *) reason="failed - $title; see the review's comments for the reason" ;;
  esac
  [ "$auto" != cleared ] || reason="$reason; auto-merge was cleared, so CRUX will not retry"
  printf '%s\n' "$reason"
}
