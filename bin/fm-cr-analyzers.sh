#!/usr/bin/env bash
# fm-cr-analyzers.sh - the analyzer gate firstmate runs before relaying a code
# review as ready.
#
# It reads the latest revision's CRUX analyzers (mcurl, then builder-mcp, through
# bin/fm-cr-lib.sh) and answers whether the merge-gating ones are green. An
# analyzer whose pass_required_for is non-empty gates the merge and must be Pass;
# one required for nothing is advisory and never blocks.
#
#   exit 0  GREEN       every merge-gating analyzer passed and measured something,
#                       or is an Integration Tests skip with a structural reason
#   exit 1  RED         a merge-gating analyzer is not Pass; each is named with
#                       its status message so the real reason can be relayed
#   exit 3  ABSTAINED   nothing gating failed, but at least one gating Pass
#                       measured nothing ("Private package, no permissions to
#                       scan", a Change Guardian skip with no infrastructure
#                       code). Relay it as passing where measured and name the
#                       abstainers; never count it as all green.
#   exit 4  UNREADABLE  neither credential path read the review, or it carries
#                       no analyzers array; it is reported neither green nor red
#   exit 2  usage or bad input
#
# FM_CR_ANALYZERS_BODY injects a captured revision or builder-mcp body, so a
# test runs the whole verdict with no network.
# Usage: fm-cr-analyzers.sh <CR-<digits>|review URL>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-cr-lib.sh
. "$SCRIPT_DIR/fm-cr-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-cr-analyzers.sh <CR-<digits>|https://code.amazon.com/reviews/CR-<digits>>
  Analyzer gate for relaying a code review as ready.
    exit 0  GREEN       every merge-gating analyzer passed and measured something
    exit 1  RED         a merge-gating analyzer is not Pass
    exit 3  ABSTAINED   nothing gating failed, but a gating Pass measured nothing
    exit 4  UNREADABLE  the review could not be read
    exit 2  usage or bad input
EOF
  exit 2
}

case "${1:-}" in
  ''|-h|--help) usage ;;
esac
[ "$#" -eq 1 ] || usage
command -v jq >/dev/null 2>&1 || { echo "fm-cr-analyzers: jq is required" >&2; exit 2; }
fm_cr_ref_parse "$1" || {
  echo "fm-cr-analyzers: '$1' is not CR-<digits> or a canonical code.amazon.com review URL" >&2
  exit 2
}
CR_ID=$FM_CR_ID
CR_URL=$FM_CR_URL

unreadable() {
  echo "UNREADABLE: $CR_URL - $1" >&2
  exit 4
}

# read_analyzers_body: the latest revision of any status, so a draft whose only
# revision is PENDING is assessed. Every mcurl failure tries builder-mcp first.
read_analyzers_body() {
  local probe verdict revs rev body why
  probe=$(fm_cr_mcurl_probe "https://code.amazon.com/reviews/$CR_ID/revisions")
  verdict=$(printf '%s' "$probe" | head -1)
  revs=$(printf '%s' "$probe" | sed '1d')
  if [ "$verdict" = ok ]; then
    rev=$(printf '%s' "$revs" | jq -r 'max_by(.review_revision_summary.id.review_revision_id.revision) | .review_revision_summary.id.review_revision_id.revision // empty' 2>/dev/null) || rev=
    if [ -n "$rev" ] && body=$(fm_cr_revision_json "$CR_ID" "$rev"); then
      printf '%s' "$body"
      return 0
    fi
  fi
  case "$verdict" in
    posture) why="mcurl blocked by an AEA posture check (mwinit will not fix this)" ;;
    denied) why="mcurl auth rejected (Midway cookie expired? run mwinit)" ;;
    ok) why="mcurl could not deliver the revision body" ;;
    *) why="mcurl could not reach CRUX (network? timeout?)" ;;
  esac
  fm_cr_fallback_available || unreadable "$why, and the builder-mcp fallback is unavailable (no builder-mcp on PATH)"
  body=$(fm_cr_fallback_cr_json "$CR_ID") || unreadable "$why, AND the builder-mcp fallback also failed - both credential paths are down"
  printf '%s' "$body"
}

if [ -n "${FM_CR_ANALYZERS_BODY:-}" ]; then
  BODY=$FM_CR_ANALYZERS_BODY
else
  BODY=$(read_analyzers_body)
fi

ANALYZERS=$(fm_cr_analyzers_array "$BODY") || unreadable "the review body carries no analyzers array"
GATING_TOTAL=$(fm_cr_analyzer_gating_total "$ANALYZERS") || unreadable "the analyzers array did not parse"
LINES=$(fm_cr_analyzer_lines "$ANALYZERS") || unreadable "the analyzers array did not parse"

# Integration Tests gates Merge, but these Skipped reasons are structural rather
# than a failure, so they are advisory. Each is a stable status_message substring.
BENIGN_INTEG_SKIP_REASONS=(
  "Code review contains changes to infrastructure-as-code packages"
  "No packages from the CR are built into any pipeline"
  "but none were eligible to test with ITL"
)

# A Pass carrying one of these status_message substrings measured nothing.
ABSTAINED_PASS_REASONS=(
  "no permissions to scan"
  "Analysis was skipped"
  "was skipped because"
)

is_benign_integ_skip() {  # <partner> <status> <message>
  local reason
  [ "$1" = "Integration Tests" ] && [ "$2" = Skipped ] || return 1
  for reason in "${BENIGN_INTEG_SKIP_REASONS[@]}"; do
    case "$3" in *"$reason"*) return 0 ;; esac
  done
  return 1
}

is_abstained_pass() {  # <message>
  local reason
  for reason in "${ABSTAINED_PASS_REASONS[@]}"; do
    case "$1" in *"$reason"*) return 0 ;; esac
  done
  return 1
}

blockers=
advisories=
abstained=
benign_skips=0
while IFS="$(printf '\t')" read -r class partner status message; do
  [ -n "$class" ] || continue
  line="$partner: $status - $message"
  case "$class" in
    blocking)
      if is_benign_integ_skip "$partner" "$status" "$message"; then
        benign_skips=$(( benign_skips + 1 ))
        advisories=${advisories:+$advisories$'\n'}$line
      else
        blockers=${blockers:+$blockers$'\n'}$line
      fi
      ;;
    advisory) advisories=${advisories:+$advisories$'\n'}$line ;;
    gating-pass)
      if is_abstained_pass "$message"; then
        abstained=${abstained:+$abstained$'\n'}$line
      fi
      ;;
  esac
done <<EOF
$LINES
EOF

print_lines() {  # <heading> <lines>
  [ -n "$2" ] || return 0
  echo "$1"
  printf '%s\n' "$2" | while IFS= read -r l; do printf '  %s\n' "$l"; done
}

abstained_count=0
[ -z "$abstained" ] || abstained_count=$(printf '%s\n' "$abstained" | grep -c .)
measured=$(( GATING_TOTAL - benign_skips - abstained_count ))

if [ -n "$blockers" ]; then
  print_lines "RED: $CR_URL - merge-gating analyzers not Pass:" "$blockers"
  print_lines "passed without measuring anything:" "$abstained"
  print_lines "advisory (not blocking):" "$advisories"
  echo "fm-cr-analyzers: gate red - do not relay this review as ready" >&2
  exit 1
fi

summary="$measured of $GATING_TOTAL merge-gating analyzers passed and measured something"
[ "$benign_skips" -eq 0 ] || summary="$summary, $benign_skips benign Integration Tests skip (advisory)"
if [ -n "$abstained" ]; then
  echo "ABSTAINED: $CR_URL - $summary; $abstained_count passed without measuring anything:"
  printf '%s\n' "$abstained" | while IFS= read -r l; do printf '  %s\n' "$l"; done
  print_lines "advisory (not blocking):" "$advisories"
  exit 3
fi
echo "GREEN: $CR_URL - $summary"
print_lines "advisory (not blocking):" "$advisories"
exit 0
