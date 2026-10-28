#!/usr/bin/env bash
# fm-cr-poll.sh - one watcher poll of a recorded CRUX code review.
#
# bin/fm-cr-check.sh arms a trusted state/<id>.check.sh shim that runs this
# script on the watcher's check cadence. Under the watcher's check contract,
# output wakes firstmate and silence means no news. It prints one line per
# actionable transition, each at most once:
#   cr-shipped                    the review landed; cleanup is unblocked
#   cr-abandoned                  closed, abandoned, or withdrawn without landing
#   cr-needs-revision: <N> new    the unresolved reviewer-comment set gained ids,
#                                 including comments on a draft latest revision,
#                                 which `cr -r` would replace in place
#   cr-no-destination: <url> (packages: ...)
#                                 a package would ship with no destination branch,
#                                 so CRUX cannot merge it
#   cr-comment-baseline: ...      the comment set moved to the other credential
#                                 path and was re-baselined
#   cr-watcher-stale: <reason>    the poll cannot see the review
#
# A stale reason re-emits on a backoff (FM_CR_STALE_BACKOFF, default 1h, 4h,
# then daily), so a permanently broken poll keeps saying so and silence always
# means no news. A failed mcurl read falls back to builder-mcp before anything
# is declared stale (bin/fm-cr-lib.sh owns both credential paths).
#
# Dedupe state lives in two sidecars written by tmp+rename:
#   state/<id>.cr-seen       cr=, state=<shipped|abandoned|in-review|draft|stale>,
#                            comments=, source=<mcurl|fallback>, and for stale
#                            stale_reason=, stale_since=, stale_emitted=,
#                            stale_reminders=
#   state/<id>.cr-dest-seen  cr=, state=<ok|missing>, missing_pkgs=
# A sidecar that names another CR is ignored.
#
# Usage: fm-cr-poll.sh <task-id> <cr-url>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-cr-lib.sh
. "$SCRIPT_DIR/fm-cr-lib.sh"

if [ "$#" -ne 2 ] || ! fm_pr_task_id_valid "$1" || ! fm_cr_url_parse "$2"; then
  echo "cr-watcher-stale: invalid CR poll request"
  exit 0
fi
ID=$1
CR_URL=$FM_CR_URL
CR_ID=$FM_CR_ID
SEEN="$STATE/$ID.cr-seen"
DEST_SEEN="$STATE/$ID.cr-dest-seen"
STALE_BACKOFF=${FM_CR_STALE_BACKOFF:-3600 14400 86400}

read_seen_field() {
  local file=$1 key=$2 owner
  [ -f "$file" ] || return 0
  owner=$(sed -n 's/^cr=//p' "$file" | head -1)
  [ -z "$owner" ] || [ "$owner" = "$CR_URL" ] || return 0
  sed -n "s/^${key}=//p" "$file" | head -1
}

# write_seen <state> [comments] [stale_reason] [stale_since] [stale_emitted]
#            [source] [stale_reminders]
write_seen() {
  local tmp
  tmp=$(mktemp "$SEEN.XXXXXX") || return 1
  printf 'cr=%s\nstate=%s\n' "$CR_URL" "$1" > "$tmp"
  [ -z "${2:-}" ] || printf 'comments=%s\n' "$2" >> "$tmp"
  [ -z "${3:-}" ] || printf 'stale_reason=%s\n' "$3" >> "$tmp"
  [ -z "${4:-}" ] || printf 'stale_since=%s\n' "$4" >> "$tmp"
  [ -z "${5:-}" ] || printf 'stale_emitted=%s\n' "$5" >> "$tmp"
  [ -z "${6:-}" ] || printf 'source=%s\n' "$6" >> "$tmp"
  [ -z "${7:-}" ] || printf 'stale_reminders=%s\n' "$7" >> "$tmp"
  mv -f -- "$tmp" "$SEEN"
}

write_dest_seen() {
  local tmp
  tmp=$(mktemp "$DEST_SEEN.XXXXXX") || return 1
  printf 'cr=%s\nstate=%s\n' "$CR_URL" "$1" > "$tmp"
  [ -z "${2:-}" ] || printf 'missing_pkgs=%s\n' "$2" >> "$tmp"
  mv -f -- "$tmp" "$DEST_SEEN"
}

fmt_age() {
  local s=$1
  if [ "$s" -ge 86400 ]; then printf '%dd' "$(( s / 86400 ))"
  elif [ "$s" -ge 3600 ]; then printf '%dh' "$(( s / 3600 ))"
  else printf '%dm' "$(( s / 60 ))"
  fi
}

# emit_stale <reason>: a new or changed reason emits at once; an unchanged one
# emits again once the next backoff step has passed, holding at the last step.
# The recorded comment set rides through a stale period, so a recovered read
# does not replay known comments as new.
emit_stale() {
  local reason=$1 prev_state prev_reason keep_comments keep_source since emitted sent now age step
  prev_state=$(read_seen_field "$SEEN" state)
  prev_reason=$(read_seen_field "$SEEN" stale_reason)
  keep_comments=$(read_seen_field "$SEEN" comments)
  keep_source=$(read_seen_field "$SEEN" source)
  now=$(date +%s)
  if [ "$prev_state" != stale ] || [ "$prev_reason" != "$reason" ]; then
    write_seen stale "$keep_comments" "$reason" "$now" "$now" "$keep_source" 1 || true
    echo "cr-watcher-stale: $reason"
    return 0
  fi
  since=$(read_seen_field "$SEEN" stale_since)
  emitted=$(read_seen_field "$SEEN" stale_emitted)
  sent=$(read_seen_field "$SEEN" stale_reminders)
  case "$since" in ''|*[!0-9]*) since=$now ;; esac
  case "$emitted" in
    ''|*[!0-9]*)
      write_seen stale "$keep_comments" "$reason" "$since" "$now" "$keep_source" 1 || true
      echo "cr-watcher-stale: $reason (persisting)"
      return 0
      ;;
  esac
  case "$sent" in ''|*[!0-9]*) sent=1 ;; esac
  # shellcheck disable=SC2086  # the backoff is a word list
  step=$(printf '%s\n' $STALE_BACKOFF | sed -n "${sent}p")
  # shellcheck disable=SC2086
  [ -n "$step" ] || step=$(printf '%s\n' $STALE_BACKOFF | tail -1)
  case "$step" in ''|*[!0-9]*) step=86400 ;; esac
  if [ "$(( now - emitted ))" -ge "$step" ]; then
    age=$(( now - since ))
    [ "$age" -ge 0 ] || age=0
    write_seen stale "$keep_comments" "$reason" "$since" "$now" "$keep_source" "$(( sent + 1 ))" || true
    echo "cr-watcher-stale: $reason (persisting $(fmt_age "$age"))"
  fi
}

merge_ids() {
  [ $# -gt 0 ] || return 0
  printf '%s\n' "$@" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

# count_new <prev-ids> <curr-ids>: ids in <curr-ids> absent from <prev-ids>.
count_new() {
  awk -v prev="$1" -v curr="$2" '
    BEGIN {
      split(prev, p, " "); for (i in p) seen[p[i]] = 1;
      split(curr, c, " "); for (i in c) if (c[i] != "" && !(c[i] in seen)) n++;
      print n+0;
    }'
}

# One builder-mcp read per poll serves both the destination guard and the
# status fallback.
FB_BODY=
FB_TRIED=0
fallback_body() {
  if [ "$FB_TRIED" = 0 ]; then
    FB_TRIED=1
    if fm_cr_fallback_available; then
      FB_BODY=$(fm_cr_fallback_cr_json "$CR_ID") || FB_BODY=
    fi
  fi
  [ -n "$FB_BODY" ] || return 1
  printf '%s' "$FB_BODY"
}

prev_state=$(read_seen_field "$SEEN" state)
prev_comments=$(read_seen_field "$SEEN" comments)
prev_source=$(read_seen_field "$SEEN" source)
[ -n "$prev_source" ] || prev_source=mcurl
source=mcurl

# The destination guard runs before the status read, so a draft whose only
# revision is PENDING is assessed. When it cannot assess, it stays silent and
# the status read below owns the stale report.
dest_rc=0
missing_dest=$(fm_cr_missing_destination "$CR_ID") || dest_rc=$?
if [ "$dest_rc" = 3 ] && dest_fb=$(fallback_body); then
  missing_dest=$(fm_cr_fallback_missing_destination "$dest_fb") && dest_rc=0
fi
if [ "$dest_rc" = 0 ]; then
  missing_dest=$(printf '%s' "$missing_dest" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
  prev_dest_state=$(read_seen_field "$DEST_SEEN" state)
  prev_dest_pkgs=$(read_seen_field "$DEST_SEEN" missing_pkgs)
  if [ -n "$missing_dest" ]; then
    if [ "$prev_dest_state" != missing ] || [ "$prev_dest_pkgs" != "$missing_dest" ]; then
      write_dest_seen missing "$missing_dest" || true
      echo "cr-no-destination: $CR_URL (packages: $missing_dest)"
    fi
  else
    [ "$prev_dest_state" = ok ] || write_dest_seen ok "" || true
  fi
fi

status=
comments=
comments_degraded=0
draft_note=
draft_unread=0
rev=

# try_fallback <why>: read status and comments through builder-mcp; 0 on success.
try_fallback() {
  local why=$1 fb fb_status
  if ! fm_cr_fallback_available; then
    emit_stale "$why; builder-mcp fallback unavailable (no builder-mcp on PATH)"
    return 1
  fi
  if ! fb=$(fallback_body); then
    emit_stale "$why AND builder-mcp fallback also failed - both credential paths are down"
    return 1
  fi
  fb_status=$(fm_cr_fallback_status "$fb")
  if [ -z "$fb_status" ]; then
    emit_stale "$why; builder-mcp fallback returned no status field"
    return 1
  fi
  # A draft's latest revision is PENDING; with no comment data there is
  # nothing published to assess, and the poll is running blind.
  if [ "$fb_status" = PENDING ]; then
    if fm_cr_fallback_has_comments "$fb"; then
      status=PENDING
      source=fallback
      comments=$(fm_cr_fallback_comment_ids "$fb" || true)
      draft_note=" (the latest revision is an unpublished draft, which cr -r would replace in place)"
      return 0
    fi
    emit_stale "mcurl is down and the builder-mcp fallback sees only an unpublished (PENDING) revision, so CR state cannot be assessed; $why"
    return 1
  fi
  status=$fb_status
  source=fallback
  if fm_cr_fallback_has_comments "$fb"; then
    comments=$(fm_cr_fallback_comment_ids "$fb" || true)
  else
    # The affordable read carries no comments, so the known set carries forward
    # rather than reading as emptied.
    comments=$prev_comments
    source=$prev_source
    comments_degraded=1
  fi
  return 0
}

probe=$(fm_cr_mcurl_probe "https://code.amazon.com/reviews/$CR_ID/revisions")
verdict=$(printf '%s' "$probe" | head -1)
revs=$(printf '%s' "$probe" | sed '1d')

case "$verdict" in
  ok)
    if ! rev=$(printf '%s' "$revs" | jq -r '[.[] | select(.review_revision_summary.status != "PENDING")] | max_by(.review_revision_summary.id.review_revision_id.revision) | .review_revision_summary.id.review_revision_id.revision // empty' 2>/dev/null) \
      || ! draft_rev=$(printf '%s' "$revs" | jq -r '[.[].review_revision_summary] | max_by(.id.review_revision_id.revision) | select(.status == "PENDING") | .id.review_revision_id.revision // empty' 2>/dev/null); then
      emit_stale "jq failed parsing revisions"
      exit 0
    fi
    [ -n "$rev" ] || [ -n "$draft_rev" ] || exit 0
    if [ -z "$rev" ]; then
      status=PENDING
    elif ! data=$(fm_cr_mcurl_get "https://code.amazon.com/reviews/$CR_ID/revisions/$rev.json"); then
      try_fallback "mcurl failed fetching revision $rev" || exit 0
    else
      if ! status=$(printf '%s' "$data" | jq -r '.revision.cr_revision.status // empty' 2>/dev/null); then
        emit_stale "jq failed parsing status"
        exit 0
      fi
      [ -n "$status" ] || { emit_stale "CRUX returned no status field"; exit 0; }
      # A set, not a count, so adding one comment while fixing another still wakes.
      comments=$(fm_cr_unresolved_comment_ids "$data" || true)
    fi
    if [ -n "$draft_rev" ] && [ "$source" = mcurl ]; then
      if ! draft_data=$(fm_cr_mcurl_get "https://code.amazon.com/reviews/$CR_ID/revisions/$draft_rev.json"); then
        draft_unread=1
        if [ -n "$rev" ]; then
          # shellcheck disable=SC2046,SC2086  # word lists of ids
          draft_ids=$(merge_ids $(printf '%s\n' $prev_comments | grep "^$draft_rev:"))
        else
          draft_ids=$prev_comments
        fi
        # shellcheck disable=SC2086
        [ -z "$draft_ids" ] || comments=$(merge_ids $comments $draft_ids)
      else
        draft_ids=$(fm_cr_unresolved_comment_ids "$draft_data" || true)
        if [ -n "$draft_ids" ]; then
          # Post ids restart at 1 on a draft above a published revision, so they
          # are keyed <revision>:<post>; a draft-only CR keeps bare ids.
          # shellcheck disable=SC2046,SC2086
          [ -z "$rev" ] || draft_ids=$(merge_ids $(printf '%s\n' $draft_ids | sed "s/^/$draft_rev:/"))
          # shellcheck disable=SC2086
          comments=$(merge_ids $comments $draft_ids)
          draft_new=$(count_new "$prev_comments" "$draft_ids")
          [ "$draft_new" -le 0 ] || draft_note=" ($draft_new on unpublished draft revision $draft_rev, which cr -r would replace in place)"
        fi
      fi
    fi
    ;;
  posture)
    try_fallback "mcurl blocked by an AEA posture check (mwinit will not fix this)" || exit 0
    ;;
  denied)
    try_fallback "mcurl auth rejected fetching revisions (Midway cookie expired? run mwinit)" || exit 0
    ;;
  *)
    try_fallback "mcurl could not reach CRUX fetching revisions (network? timeout?)" || exit 0
    ;;
esac

case "$status" in
  SHIPPED|MERGED)
    if [ "$prev_state" != shipped ]; then
      write_seen shipped "$comments" "" "" "" "$source" || true
      echo "cr-shipped"
    fi
    ;;
  ABANDONED|CLOSED|WITHDRAWN)
    if [ "$prev_state" != abandoned ]; then
      write_seen abandoned "$comments" "" "" "" "$source" || true
      echo "cr-abandoned"
    fi
    ;;
  PUBLISHED|REVIEW_OUTSTANDING|REVIEW_COMPLETED|OPEN|IN_REVIEW|PENDING)
    if [ "$comments_degraded" = 1 ]; then
      emit_stale "reviewer-comment tracking blind: mcurl is down and the builder-mcp fallback cannot afford the comment fetch inside FM_CHECK_TIMEOUT; read comments through builder-mcp directly (set FM_CR_FALLBACK_COMMENTS=1 with a longer FM_CHECK_TIMEOUT to re-enable)"
      exit 0
    fi
    review_state=in-review
    [ "$status" != PENDING ] || review_state=draft
    # Comments first seen on a draft were keyed <revision>:<post>; once that
    # revision is published they return as bare post ids.
    case " $prev_comments" in
      *" ${rev:-none}:"*)
        # shellcheck disable=SC2046,SC2086
        prev_comments=$(merge_ids $(printf '%s\n' $prev_comments | sed "s/^$rev://"))
        ;;
    esac
    new_count=0
    if [ "$source" = "$prev_source" ] && [ -n "$comments" ]; then
      new_count=$(count_new "$prev_comments" "$comments")
    fi
    if [ "$source" != "$prev_source" ]; then
      # The two paths mint different id vocabularies, so a path switch
      # re-baselines rather than claiming every id is new.
      write_seen "$review_state" "$comments" "" "" "" "$source" || true
      echo "cr-comment-baseline: switched to $source credential path, comment set re-baselined$draft_note"
    elif [ "$comments" != "$prev_comments" ]; then
      write_seen "$review_state" "$comments" "" "" "" "$source" || true
      [ "$new_count" -le 0 ] || echo "cr-needs-revision: $new_count new$draft_note"
    fi
    if [ "$draft_unread" = 1 ]; then
      if [ -n "$rev" ]; then
        emit_stale "mcurl failed fetching draft revision $draft_rev, so reviewer comments on it are unassessed; the published revision was read"
      else
        emit_stale "mcurl failed fetching draft revision $draft_rev, the CR's only revision, so nothing on the CR was assessed"
      fi
    fi
    ;;
  *)
    emit_stale "unknown CR status '$status'"
    ;;
esac
exit 0
