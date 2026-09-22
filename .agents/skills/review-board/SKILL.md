---
name: review-board
description: >-
  Agent-only reference for rendering the captain-facing code-review board from CRUX, with dry-run status and analyzer comment counts.
  Load before telling the captain the state of any code review, and before rendering a table of several; a worker's status line is never current review state.
user-invocable: false
metadata:
  internal: true
---

# review-board

Load this before telling the captain the state of any code review, and before rendering a table of several.

It exists because firstmate repeatedly reported reviews as green by reading a worker's prose status line.
A worker writes `dry run wor...` while a build is still running, or reports green on the revision it uploaded while a later analyzer has since failed.
The captain found a failing dry run on a review this board had listed as green.
A worker's report is evidence about what it did; it is never current review state.

## The one rule

Read review state from the service, not from a status log, not from a `done:` line, and not from memory.

## How to read it

**For a board, use `get-approval-status`.** It is the cheapest call that carries dry-run state:

```
CodeReviewReadActions: action=get-approval-status, cr=CR-XXXXXXXXX
```

It returns every analyzer with its `status`, `statusMessage` and build URL, plus `revisionStatus`,
`reviewerApprovals` and `unresolvedCriticalCommentCount` - the whole board except `merged`.
It costs roughly a tenth of the revision read below, because it carries no description and no commit
bodies, and a fleet-sized board read the expensive way burns tens of thousands of tokens for data this
call already has.

Pair it with one dashboard read to sweep the whole fleet at once:

```
ReadInternalWebsites: https://code.amazon.com/reviews/from-user/<alias>
```

That one call gives every review's id, latest revision, summary and `PENDING`/`OPEN`/`SHIPPED` status, so
use it to find which reviews are worth a per-review call rather than polling a remembered list - a list
held in conversation goes stale the moment the captain publishes something.

Read the full revision only when the board needs the description, the file list, or `auto_publish`:

```
ReadInternalWebsites: https://code.amazon.com/reviews/<CR>/revisions/<N>?diffConfig=none
```

Omit `/revisions/<N>` for the latest.
`diffConfig=none` skips diff computation, which is the expensive part and never what the board needs.

From that fuller response:

| Board column | Where it comes from |
|---|---|
| Dry run | `analyzers[]` entry whose `partner_id` is `Dry Run Build` - its `status` plus the build URL in `status_message` |
| Analyzer comments | `revisionDetails.revision.cr_revision.comments` length, and `AutoSDE - CR reviewer`'s `status_message` |
| Blocked analyzers | any `analyzers[]` entry with `status` `Blocked`, which usually means it is waiting on the dry run |
| Published | `status` - `PENDING` is a draft, `OPEN` is published, `SHIPPED` means it landed |
| Merged | `merged` on `get-cr-info`, true once any revision ships |
| Brake | `approval_map` - a row with `minimum` >= 1 and `granted` 0 genuinely holds a merge |
| Publish gate | `auto_publish`, and whether `completed_actions` contains `PUBLISH_CR` |

`get-cr-info` is the one call that reports `merged`, but it returns the whole description, so it is not
cheap - prefer the dashboard read for status and reach for this only when landing must be proven.
`get-cr-comments` returns the comment bodies.

## What the board must show

Never present a review without its dry-run state.
A review with a failing or running dry run is not green, however many other analyzers pass.

Render every identifier as a markdown link, including build ids - `data/captain-shared.md` owns that rule.

Say which of these each review is, in the captain's words rather than analyzer vocabulary:

- **Ready for you** - dry run passed, analyzers passed, still a draft.
- **Build failing** - name the failing build and what it was.
- **Build running** - say so rather than implying either outcome.
- **Waiting on a comment** - unresolved analyzer or reviewer comments, with the count.
- **Landed** - `merged` true.

## Three traps

`Blocked` on Change Guardian or Coverlay almost always reads `Waiting for dry run to pass`.
That is one failure - the dry run - surfacing three times.
Report the dry run, not three blocked analyzers, or the board reads as three times worse than it is.

**A `Pass` that measured nothing is not a pass.** On RewindApp two analyzers routinely report `Pass` without running:
Security Code Scanner says `Private package, no permissions to scan`, and Change Guardian skips when it recognizes no
infrastructure-as-code artifacts.
So "all six analyzers pass" can mean four measured and two abstained.
Read each `status_message` rather than counting `Pass` values, and say how many actually measured when it matters -
for a docs-only change two abstentions are irrelevant, but claiming six green is the same overclaim this skill exists
to stop.

`next_actions` offering `PUBLISH_CR` to the captain means CRUX is offering him the button now the gates pass.
It is not evidence anything published itself.
`completed_actions` containing `PUBLISH_CR` is.
