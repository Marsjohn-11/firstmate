# no-mistakes Test gate — live validation

Driven against `bin/fm-no-mistakes-test.sh` at 46e7537, the command `.no-mistakes.yaml`
now pins to `commands.test`.

## The configured workload is deterministic and complete

`--list-plan` assigns all 213 discovered `tests/*.test.sh` files to exactly 8 lanes:

| lane | tests |
|---|---|
| portable-parallel-1 | 11 |
| portable-parallel-2 | 13 |
| portable-serial-1of5 | 34 |
| portable-serial-2of5 | 34 |
| portable-serial-3of5 | 35 |
| portable-serial-4of5 | 35 |
| portable-serial-5of5 | 35 |
| real-herdr-gated | 16 |

`--check-plan` on that plan prints `FM_TEST_PLAN ok total=213 lanes=8`.

## End-to-end gate runs

Each run below is the real `bin/fm-no-mistakes-test.sh` executing all 8 lanes in
isolated concurrent clones. Test bodies were stubbed in a scratch clone so the
gate's own plan/clone/aggregate/summary path could be driven at speed; the lane
derivation, coverage check, concurrency, timing artifacts, aggregate check and
summary arithmetic are the shipped code.

| host condition | gate exit | FM_TEST_GATE_SUMMARY |
|---|---|---|
| every prerequisite present | 0 | `lanes=8 total=213 passed=213 failed=0 skipped_gate=0` |
| Herdr binary absent (required) | 1 | `lanes=8 total=213 passed=197 failed=0 skipped_gate=16` |
| Pi package present, tsc missing | 1 | `lanes=8 total=213 passed=212 failed=0 skipped_gate=1` |
| one script asserts failure | 1 | `lanes=8 total=213 passed=212 failed=1 skipped_gate=0` |

Every run emits one machine-parseable total with passed, failed and skipped
counts, and `passed = total - failed - skipped_gate` holds in all four.

## The Pi requirement reaches one lane, and only capable hosts

`tests/fm-pi-primary-types.test.sh` is planned into `portable-parallel-1`.
`--required-skips` emits the Pi token only when npm, tsc and the Pi package are
all present, and only for that lane. In the Pi-required gate run above,
`portable-parallel-1` exited 1 while `portable-parallel-2` and all five serial
shards exited 0.

## Refusals

- a discovered test in zero lanes → named, exit 1
- a test in two lanes → named, exit 1
- a planned test absent from discovery → named, exit 1
- a malformed plan row → named, exit 1
- an inventory with zero tests → `lane 'portable-serial-1of5' selected zero tests`, exit 2, nothing executed
