# Kiro CLI adapter verification

Maintainer-verification record for the `kiro` crewmate/scout adapter (V2 engine).
It records the active empirical facts the adapter depends on and the exact commands that establish them.
The live drift guard `tests/fm-kiro-signals-live-e2e.test.sh` (family `live-harness-optin`, control `FM_KIRO_SIGNALS_LIVE`) is what refreshes the vendor-controlled facts below; run it after every kiro upgrade.

Scope: V2 engine only (`--agent-engine v2`). The v3/KAS engine is out of scope and was not exercised: it is unsupported on this Amazon Linux 2 host and its hooks are not yet at parity.

## Environment

- Date: 2026-09-13.
- Host: Amazon Linux 2 (Linux 5.10, x86_64).
- Tool: `kiro-cli 2.21.4`, installed via toolbox at `~/.toolbox/bin/kiro-cli` (a bash sandbox shim that runs `aim sandbox --client kiro-cli`, whose descendant is the compiled bun/node binary).
- Auth: a signed-in account; auth state lives in the XDG data dir `~/.local/share/kiro-cli/data.sqlite3`, not under `KIRO_HOME`.

## Agent-config hooks are claude-shaped (V2)

`kiro-cli agent validate --path <file>` is strict: an unknown hook trigger or a wrong value type is rejected.

```
$ kiro-cli agent validate --path config-with-hooks-stop-and-userPromptSubmit.json   # exit 0 (accepted)
$ kiro-cli agent validate --path config-with-bogus-trigger.json
Error: Json ... did not match any variant of untagged enum Repr ...                  # rejected
```

So `hooks.userPromptSubmit` and `hooks.stop`, each an array of `{"command": "..."}`, are accepted V2 triggers.
Both fired per turn in a real run (non-interactive and interactive TUI), with bare `touch` hook commands and no stdout contract:

```
$ KIRO_HOME=<per-task> kiro-cli chat --agent-engine v2 --agent firstmate --trust-all-tools --no-interactive "say hi in one word"
Hi
# both the userPromptSubmit and stop hook marker files were created
```

`stop` does NOT fire on a manual Escape interrupt (the claude behaviour), and no StopFailure/SessionEnd equivalent was found among the accepted triggers.
Those bare commands carry no shell metacharacter, so this run establishes nothing about whether kiro shell-interprets a command string - which the spawn's compound hook commands depend on, and which the live guard now asserts.

## Out-of-tree config via KIRO_HOME; `--agent` is name-only

`--agent` takes a NAME resolved from the global `KIRO_HOME/agents/` dir plus the workspace `<cwd>/.kiro/agents/`; a path is rejected:

```
$ kiro-cli chat --agent-engine v2 --agent /abs/path/to/config.json --no-interactive "hi"
[warn] failed to set agent '/abs/path/to/config.json': Internal error   # falls back to default
```

`KIRO_HOME` relocates the global config root (agents + settings + sessions) but not auth:

```
$ KIRO_HOME=/tmp/kh kiro-cli agent list
Global:    /tmp/kh/agents          # relocated
# /tmp/kh/{agents,settings} created; auth untouched, chat turns still authenticate
```

So the spawn writes `state/<id>.kiro-home/agents/firstmate.json` (the hook config) and reaches it with `KIRO_HOME=state/<id>.kiro-home --agent firstmate`, never writing into the worktree's own `.kiro/`.

## Trust modal and its suppression setting

`--trust-all-tools` blocks on a modal on first use:

```
Warning: Kiro is running in trust all tools mode
❯ No, exit
  Yes, I accept
  Yes, and don't ask again
```

Selecting "Yes, and don't ask again" persists exactly:

```
$ cat $KIRO_HOME/settings/cli.json
{ "chat.disableTrustAllConfirmation": true }
```

Seeding that setting into the per-task `KIRO_HOME` suppresses the modal, and a positional brief then auto-submits with no extra Enter on a fresh worktree (verified: pane showed `• ready`, both hooks fired).

## Rendered surface (V2 TUI)

- Composer glyph: `›` (U+203A), the same glyph codex draws.
- Idle placeholder: `ask a question or describe a task` (followed by a de-emphasised `↵`), rendered dim, so a styled capture strips it back to the bare glyph and an unstyled one degrades to `unknown` through the bare-row rule.
- Busy footer: `› Kiro is working · Type to steer · Ctrl+S to queue`. The delivery guard matches the harness-named `Kiro is working` literal, not the bare `esc to cancel` token kiro also renders in its tool region and shares with agy. It is never a recorded worker state, and its one reachable consumer is the harness-less union in `FM_DELIVERY_BUSY_REGEX_DEFAULT` that the tmux submit core reads to acknowledge a submit.
`FM_DELIVERY_KIRO_BUSY_REGEX_DEFAULT` is registered per the fleet convention that every verified harness declares its own signature, and has no caller today: away-mode injection reads the primary harness and the pending-reply observation reads a secondmate's harness, neither of which kiro can ever be.

## Control

- Interrupt: a single `Escape` prints `● Cancelled ...` and returns a clean idle composer with no repollution, so no clear key follows.
- Exit: `/quit` prints `Session ended.` then `Resume with: kiro-cli --resume-id <session-id>`.
- Resume: `--resume-id <id>` (id from the exit line) or `--resume` (most recent for the cwd); sessions live under the per-task `KIRO_HOME`. Firstmate automates only `relaunch` from the durable brief.

## Detection and liveness

- The live foreground process name is `kiro-cli` (`tmux #{pane_current_command}` and `ps -o comm=` both report `kiro-cli`; `aim sandbox` and the compiled binary run as descendants).
- No `KIRO_*` identity marker is exported to tool subprocesses, so detection is ancestry alone on the anchored name `kiro-cli`.

## Model and effort

- `kiro-cli chat --agent-engine v2 --list-models -f json` returns `{"models":[{"model_id":"<id>"},...],"default_model":"auto"}`; ids are bare (`auto`, `claude-opus-5`, ...). The spawn refuses a requested id a reachable listing omits and launches unvalidated with a notice when the listing is unreachable or hung.
- `--effort` accepts `low|medium|high|xhigh|max` (per `kiro-cli chat --help`), so the full shared vocabulary passes through.

## Live guard result

`FM_KIRO_SIGNALS_LIVE=1 tests/fm-kiro-signals-live-e2e.test.sh` passed on 2026-09-13 against kiro-cli 2.21.4: the busy footer matched in flight, the launch prompt was answered, both V2 hooks fired per turn, a single Escape cancelled a long turn, and `/quit` stopped the process and printed its resume-id line.
Two parts of the guard changed after that run, so its recorded pass is evidence for the vendor facts above and not for what the guard checks today.
Its footer matcher now folds the captured screen and calls the delivery guard `fm_busy_lines_match kiro` instead of a classifier helper the adapter no longer has.
Its hook commands now carry the shell constructs the spawn emits - a `;`-joined pair with a `2>/dev/null || true` tail whose awaited marker comes from a redirect - where the recorded run used bare `touch` commands, so whether kiro shell-interprets a hook command string is asserted but not yet observed.
Re-running the guard on the Linux desk where the real tool lives is what would prove both.

## What is NOT verified

- The v3/KAS engine (out of scope; unsupported on AL2, hooks not yet at parity).
- Any StopFailure/SessionEnd-equivalent hook trigger (none found). On an abnormal turn end (a stream or API error, a model-side abort) the `stop` hook never fires, so the busy record stays open and the supervisor reads the worker as provably working - deferring instead of surfacing or retiring the endpoint - until the next `userPromptSubmit` re-opens the record. The rendered footer does not rescue it: it is a delivery guard only and the classifier has no kiro pane arm.
- Primary or secondmate operation: no supervision protocol exists, and `bin/fm-spawn.sh` refuses a secondmate launch.
- Backends other than tmux for the rendered surface (the portable regression drives the signals apart with real processes; the live guard exercises tmux).
