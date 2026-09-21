# Live validation — stale lock recovery no longer recurses

Driven on darwin 25.6.0 against the real products in this branch (`bin/fm-watch.sh`,
`bin/fm-send.sh`) with isolated homes under `/tmp/fmlivetest`, plus the same drives at the
base commit `dee119b` for a red baseline. No Herdr session, no real fleet state, no
default-session pane was touched.

## 1. The watcher recovers a home wedged by stacked steal-mutex residue

Fixture: a home whose `.watch.lock` is stale (dead pid) and which carries 40 stacked
`<lock>.steal…` residue directories, the shape a crashed stealer leaves behind.

| | base `dee119b` | this branch |
|---|---|---|
| watcher took the singleton lock | never, within 45s | yes, 3s |
| `basename … File name too long` lines | 93 | 0 |
| nested `.watch.lock.steal.steal` created | yes | no |

Evidence: `watcher-recovery-base.txt`, `watcher-recovery-head.txt`,
driver `watcher-steal-residue-drive.sh`.

## 2. A captain steer lands over the same residue

Fixture: a recorded tmux task whose steering inbox holds a stale `.seq.lock` plus 40
stacked residue levels; the drive is the real `bin/fm-send.sh` (durable record is the
delivery), with the project's own documented test-harness bypass
`FM_GATE_REFUSE_BYPASS=1`.

| | base `dee119b` | this branch |
|---|---|---|
| `fm-send` outcome | still running at 60s, killed | exit 0 in 6s |
| durable record | none | `001.msg`, schema + `at=` header + body |
| `File name too long` lines | 192 | 0 |

Evidence: `steer-delivery-base.txt`, `steer-delivery-head.txt`,
driver `steer-over-steal-residue-drive.sh`.

## 3. Adversarial — the three verdicts stay apart

Same real watcher, one fixture per case, an unrelated `sleep` process standing in for the
recycled pid.

| case | seeded | watcher claimed the lock | mutex kept | unrelated process |
|---|---|---|---|---|
| live-holder | steal mutex held by a live pid whose identity still matches | no (20s) | yes | untouched |
| recycled | steal mutex whose recorded holder is gone, pid recycled onto a live process | yes (5s) | pruned | untouched |
| primary | primary `.watch.lock` whose own pid was recycled | no (20s) | n/a | untouched |

The third row is the deliberate documented limitation: the recycled-pid predicate does not
reach a primary lock's verdict.

Evidence: `watcher-mutex-exclusion-head.txt`, driver `watcher-mutex-exclusion-drive.sh`.

## 4. Targeted suites

`tests/fm-watcher-lock.test.sh` 38 ok, `tests/fm-task-inbox.test.sh` 21 ok, both exit 0 —
including the six new lock regressions and the six-writer inbox race over 40 stacked stale
mutexes. Logs: `fm-watcher-lock-suite-final.log`, `fm-task-inbox-suite-final.log`.
