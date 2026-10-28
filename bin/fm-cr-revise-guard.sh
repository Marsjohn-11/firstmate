#!/usr/bin/env bash
# fm-cr-revise-guard.sh - the check a worker runs before and after every `cr -r`.
#
# CRUX treats `cr -r` differently depending on the CR's latest revision:
#   published latest   the upload adds a new revision (latest + 1)
#   draft latest       the upload REPLACES that draft revision in place, keeping
#                      its number, and the comments on it stop showing on the CR
# So a draft revision someone has already commented on loses those comments on
# the next `cr -r`. This guard reads the CR before the upload and refuses that
# case, and after the upload it confirms the upload did what it predicted.
#
# Usage:
#   fm-cr-revise-guard.sh <CR-<digits>|review URL> [--baseline <file>]
#       Pre-upload check. With --baseline, writes the reading (predicted
#       revision, every comment key, and the blocking comments verbatim) to
#       <file> for the post-upload check and as the saved copy of the comments.
#   fm-cr-revise-guard.sh <CR-<digits>|review URL> --after <baseline-file> --uploaded <N>
#       Post-upload check. <N> is the revision number `cr` printed. Confirms N
#       is the predicted revision, CRUX's latest revision is N, and every
#       comment recorded in the baseline on a revision the upload should not
#       have touched is still there.
#
# Exit codes:
#   0  safe (pre) or confirmed (post)
#   1  blocked: the latest revision is a draft carrying a reviewer comment, so
#      `cr -r` would replace it in place
#   2  usage or baseline error: bad arguments, or a baseline file that cannot
#      be written, is not a guard baseline, or was recorded for another CR
#   3  cannot assess: CRUX could not be read on either credential path, or the
#      latest revision's status is neither a draft nor a known published
#      status. Never treated as safe.
#   4  post-upload mismatch: the revision number is not the predicted one, or a
#      recorded comment on an untouched revision is gone
#
# A reviewer comment is one whose author the shared classification in
# fm-cr-lib.sh (FM_CR_JQ_AUTHOR_DEFS) counts as a reviewer: every USER, and
# every AAA service principal that is not on its noise list of status bots. A
# draft carrying only noise-list comments (coverage reports, merge notices) is
# safe to replace. Fixed comments and replies count too, because replacing the
# draft hides them all.
#
# Reading CRUX goes through bin/fm-cr-lib.sh: an mcurl probe of the revisions
# list first, then the builder-mcp fallback when mcurl is posture-blocked,
# denied, or unreachable. The fallback read asks for every comment, so its
# timeout is FM_CR_REVISE_FALLBACK_TIMEOUT (90s) rather than the watcher's
# budget. Only the latest revision of a CR can be a draft, so the fallback's
# latest-revision status plus its all-revisions comment list is a full reading.
#
# Dependencies: jq, mcurl, and builder-mcp for the fallback. bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-cr-lib.sh
. "$SCRIPT_DIR/fm-cr-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-cr-revise-guard.sh <CR-<digits>|review URL> [--baseline <file>]
       fm-cr-revise-guard.sh <CR-<digits>|review URL> --after <baseline-file> --uploaded <N>
  Run before every `cr -r` (first form) and after it (second form).
  Exit 0 safe/confirmed, 1 blocked (draft with reviewer comments),
  2 usage, 3 cannot assess, 4 post-upload mismatch.
EOF
  exit 2
}

INPUT=
BASELINE=
AFTER=
UPLOADED=
while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) [ $# -ge 2 ] || usage; BASELINE=$2; shift 2 ;;
    --after) [ $# -ge 2 ] || usage; AFTER=$2; shift 2 ;;
    --uploaded) [ $# -ge 2 ] || usage; UPLOADED=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "error: unknown flag '$1'" >&2; usage ;;
    *)
      [ -z "$INPUT" ] || { echo "error: unexpected argument '$1'" >&2; usage; }
      INPUT=$1; shift ;;
  esac
done
[ -n "$INPUT" ] || usage
fm_cr_ref_parse "$INPUT" || {
  echo "error: '$INPUT' is not CR-<digits> or a canonical code.amazon.com review URL" >&2
  exit 2
}
CR_ID=$FM_CR_ID
CR_URL=$FM_CR_URL
if [ -n "$AFTER" ]; then
  [ -z "$BASELINE" ] || { echo "error: --after and --baseline are separate modes" >&2; usage; }
  case "$UPLOADED" in
    ''|*[!0-9]*) echo "error: --after needs --uploaded <revision-number>" >&2; usage ;;
  esac
  [ -f "$AFTER" ] || { echo "error: baseline file '$AFTER' not found" >&2; exit 2; }
elif [ -n "$UPLOADED" ]; then
  echo "error: --uploaded is only valid with --after" >&2
  usage
fi

why() {
  printf '%s\n' "$1" >> "$WHY_FILE"
}

cannot_assess() {
  echo "cannot-assess: $CR_URL: $1" >&2
  echo "Do not run cr -r. Report the reason above and wait." >&2
  exit 3
}

# read_mcurl: echo the normalized reading from the mcurl path, or return 1 when
# mcurl cannot serve it (the caller then tries the fallback). The comments come
# from fm_cr_fetch_comments, which reads the published revisions and a draft
# latest revision: the only revision that can be a draft.
read_mcurl() {
  local probe verdict list fetched rc=0
  probe=$(fm_cr_mcurl_probe "$CR_URL/revisions")
  verdict=$(printf '%s' "$probe" | head -1)
  [ "$verdict" = ok ] || { why "mcurl: probe verdict $verdict"; return 1; }
  list=$(printf '%s' "$probe" | sed '1d' | jq -c '[ .[].review_revision_summary
      | { revision: (.id.review_revision_id.revision | tonumber), status: (.status // "") } ]
      | sort_by(.revision)' 2>/dev/null) || { why "mcurl: revisions list did not parse"; return 1; }
  [ "$(printf '%s' "$list" | jq 'length')" -gt 0 ] || { why "mcurl: CR has no revisions"; return 1; }
  fetched=$(fm_cr_fetch_comments "$CR_ID") || rc=$?
  [ "$rc" = 0 ] || { why "mcurl: comment fetch failed (fm_cr_fetch_comments returned $rc)"; return 1; }
  jq -cn --argjson list "$list" --argjson fetched "$fetched" "$FM_CR_JQ_AUTHOR_DEFS"'
    { source: "mcurl",
      latest: ($list | last | .revision),
      latest_status: ($list | last | .status),
      revisions: $list,
      comments: [ $fetched[]
                  | { revision: (.revision | tonumber),
                      post: (.post_id | tostring),
                      author: (.author // "?"),
                      reviewer: fm_reviewer_author(.author_type; .author),
                      fixed: (.fixed // false),
                      location: (.location // "TOP"),
                      content: (.content // "") } ] }' 2>/dev/null \
    || { why "mcurl: comments did not parse"; return 1; }
}

# read_fallback: echo the normalized reading from builder-mcp, or return 1.
read_fallback() {
  local body latest this status
  fm_cr_fallback_available || { why "builder-mcp: no builder-mcp on PATH"; return 1; }
  body=$(FM_CR_FALLBACK_COMMENTS=1 FM_CR_FALLBACK_TIMEOUT="${FM_CR_REVISE_FALLBACK_TIMEOUT:-90}" \
    fm_cr_fallback_cr_json "$CR_ID") || { why "builder-mcp: read failed"; return 1; }
  latest=$(printf '%s' "$body" | jq -r '.content.latestRevision // empty' 2>/dev/null)
  this=$(printf '%s' "$body" | jq -r '.content.revision // empty' 2>/dev/null)
  case "$latest" in ''|*[!0-9]*) why "builder-mcp: body has no latestRevision"; return 1 ;; esac
  if [ "$this" != "$latest" ]; then
    body=$(FM_CR_FALLBACK_COMMENTS=1 FM_CR_FALLBACK_TIMEOUT="${FM_CR_REVISE_FALLBACK_TIMEOUT:-90}" \
      fm_cr_fallback_cr_json "$CR_ID" "$latest") || { why "builder-mcp: read of revision $latest failed"; return 1; }
    this=$(printf '%s' "$body" | jq -r '.content.revision // empty' 2>/dev/null)
    [ "$this" = "$latest" ] || { why "builder-mcp: asked for revision $latest and got revision ${this:-none}"; return 1; }
  fi
  fm_cr_fallback_has_comments "$body" || { why "builder-mcp: body carries no comment list"; return 1; }
  status=$(fm_cr_fallback_status "$body")
  [ -n "$status" ] || { why "builder-mcp: body has no revision status"; return 1; }
  # Each comment must say which revision and post it belongs to, or the guard
  # cannot tell whether it sits on the draft at risk.
  printf '%s' "$body" | jq -e '[ .content.allComments[]
      | select(((.revision | tostring) | test("^[0-9]+$") | not)
               or ((.post | tostring) | test("^[0-9]+$") | not)) ] | length == 0' >/dev/null 2>&1 \
    || { why "builder-mcp: a comment carries no revision or post id"; return 1; }
  printf '%s' "$body" | jq -c --argjson latest "$latest" --arg status "$status" "$FM_CR_JQ_AUTHOR_DEFS"'
    { source: "fallback",
      latest: $latest,
      latest_status: $status,
      revisions: [ range(1; $latest + 1) as $r
                   | { revision: $r, status: (if $r == $latest then $status else "PUBLISHED" end) } ],
      comments: ( [ .content.allComments[]?
                    | { revision: (.revision | tonumber),
                        post: (.post | tostring),
                        author: (.author // "?"),
                        reviewer: ((.author // "") | fm_noise_author | not),
                        fixed: (.fixed // false),
                        location: (.location // "TOP"),
                        content: (.content // "") } ]
                  | group_by([.revision, .post]) | map(last) ) }' 2>/dev/null \
    || { why "builder-mcp: body did not parse"; return 1; }
}

# The readers run in command substitutions, so they report why they failed
# through a file rather than a variable.
WHY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-cr-revise-guard.XXXXXX") || exit 3
trap 'rm -f "$WHY_FILE"' EXIT
READING=$(read_mcurl) || READING=$(read_fallback) \
  || cannot_assess "$(paste -sd ';' - < "$WHY_FILE" | sed 's/;/; /g')"

LATEST=$(printf '%s' "$READING" | jq -r '.latest')
LATEST_STATUS=$(printf '%s' "$READING" | jq -r '.latest_status')
# PENDING is a draft. Only the statuses listed here count as published. Any
# other status, terminal or unknown, cannot be assessed.
case "$LATEST_STATUS" in
  PENDING|OPEN|APPROVED|PUBLISHED|REVIEW_OUTSTANDING|REVIEW_COMPLETED|IN_REVIEW) ;;
  '') cannot_assess "revision $LATEST carries no status" ;;
  *) cannot_assess "revision $LATEST has status '$LATEST_STATUS', which is neither a draft nor a known published status" ;;
esac

# ---------------------------------------------------------------------------
# Post-upload mode
# ---------------------------------------------------------------------------
if [ -n "$AFTER" ]; then
  predicted=$(jq -r '.predicted_revision // empty' "$AFTER" 2>/dev/null)
  replaced=$(jq -r '.replaces_revision // empty' "$AFTER" 2>/dev/null)
  case "$predicted" in ''|*[!0-9]*) echo "error: '$AFTER' is not a guard baseline" >&2; exit 2 ;; esac
  baseline_cr=$(jq -r '.cr // empty' "$AFTER" 2>/dev/null)
  [ "$baseline_cr" = "$CR_URL" ] \
    || { echo "error: baseline '$AFTER' was recorded for ${baseline_cr:-no CR}, not $CR_URL" >&2; exit 2; }
  problems=
  [ "$UPLOADED" = "$predicted" ] \
    || problems="${problems}  - cr printed revision $UPLOADED, the guard predicted revision $predicted
"
  [ "$LATEST" = "$UPLOADED" ] \
    || problems="${problems}  - CRUX's latest revision is $LATEST, not the uploaded revision $UPLOADED
"
  missing=$(jq -rn --slurpfile base "$AFTER" --argjson now "$READING" --arg replaced "$replaced" '
    ($now.comments | map("\(.revision):\(.post)")) as $have
    | $base[0].comments[]
    | select(($replaced == "") or (.revision != ($replaced | tonumber)))
    | select(("\(.revision):\(.post)") as $k | ($have | index($k)) == null)
    | "  - comment \(.revision):\(.post) by \(.author) is gone"')
  [ -z "$missing" ] || problems="${problems}${missing}
"
  if [ -n "$problems" ]; then
    printf 'mismatch: the upload to %s did not do what the guard predicted:\n%s' "$CR_URL" "$problems" >&2
    echo "Report this at once with the revision list. Do not upload again." >&2
    exit 4
  fi
  echo "confirmed: $CR_URL is now at revision $UPLOADED and every earlier comment is still there"
  exit 0
fi

# ---------------------------------------------------------------------------
# Pre-upload mode
# ---------------------------------------------------------------------------
BLOCKING=$(printf '%s' "$READING" | jq -c --argjson latest "$LATEST" \
  '[ .comments[] | select(.revision == $latest and .reviewer) ]')
if [ "$LATEST_STATUS" = PENDING ]; then
  predicted=$LATEST
  replaces=$LATEST
else
  predicted=$(( LATEST + 1 ))
  replaces=
  BLOCKING='[]'
fi
blocked_count=$(printf '%s' "$BLOCKING" | jq 'length')

if [ -n "$BASELINE" ]; then
  if ! mkdir -p "$(dirname "$BASELINE")" \
    || ! jq -n --argjson reading "$READING" --argjson blocking "$BLOCKING" \
      --arg cr "$CR_URL" --argjson predicted "$predicted" --arg replaces "$replaces" '
      $reading + { cr: $cr, predicted_revision: $predicted,
                   replaces_revision: (if $replaces == "" then null else ($replaces | tonumber) end),
                   blocking_comments: $blocking }' > "$BASELINE"; then
    echo "error: could not write baseline '$BASELINE'" >&2
    exit 2
  fi
fi

if [ "$blocked_count" -gt 0 ]; then
  authors=$(printf '%s' "$BLOCKING" | jq -r '[ .[].author ] | group_by(.) | map("\(.[0]) x\(length)") | join(", ")')
  echo "blocked: cr -r would replace draft revision $LATEST of $CR_URL in place, and it carries $blocked_count reviewer comment(s) from: $authors" >&2
  printf '%s' "$BLOCKING" | jq -r '.[] | "  - \(.revision):\(.post) \(.author) at \(.location): \(.content)"' >&2
  if [ -n "$BASELINE" ]; then
    echo "The comments are saved verbatim in $BASELINE." >&2
  fi
  echo "Do not run cr -r. The draft must be published first so the upload adds a new revision." >&2
  exit 1
fi

if [ -n "$replaces" ]; then
  echo "ok: revision $LATEST of $CR_URL is an unpublished draft with no reviewer comments; cr -r will replace it in place as revision $predicted"
else
  echo "ok: revision $LATEST of $CR_URL is published; cr -r will add revision $predicted"
fi
exit 0
