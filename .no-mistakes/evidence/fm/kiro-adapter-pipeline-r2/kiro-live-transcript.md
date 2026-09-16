# Live Kiro CLI crewmate adapter — driven transcript

Host: macOS 25.6.0 · tmux 3.5a · kiro-cli 2.22.1-nightly.4 launched with `--agent-engine v2`
(the verified engine; the newer v3/KAS engine is out of scope and was never used).
Branch fm/kiro-adapter-pipeline-r2 @ 91c129e. Everything ran in a throwaway FM_HOME under
$TMPDIR with a per-task KIRO_HOME; the operator's real ~/.kiro was never written by firstmate.

## 1. The real spawn emits the real launch command and per-task home

    $ bin/fm-spawn.sh kiro-live-1 <proj> --harness kiro --mode no-mistakes --yolo off
    spawned kiro-live-1 harness=kiro kind=ship mode=no-mistakes yolo=off window=firstmate:fm-kiro-live-1

    launch line actually sent to the pane:
    env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI env -u CLAUDECODE -u PI_CODING_AGENT \
      -u GROK_AGENT -u FM_PI_HARNESS KIRO_HOME='<state>/kiro-live-1.kiro-home' \
      '/Users/marsjohn/.toolbox/bin/kiro-cli' chat --agent-engine v2 --agent firstmate \
      --trust-all-tools "$(fm-operational-input.sh encode launch-brief < <brief>)"

    generated per-task home (nothing in the worktree's own .kiro/):
      <id>.kiro-home/agents/firstmate.json          hooks: userPromptSubmit -> ..., stop -> ...
      <id>.kiro-home/hooks/user-prompt-submit       fm-busy-event.sh apply ... busy --source kiro-hook
      <id>.kiro-home/hooks/stop                     touch <id>.turn-ended; ... idle --source kiro-hook
      <id>.kiro-home/settings/cli.json              {"chat.disableTrustAllConfirmation":true}

## 2. That command run in a real tmux pane against the real tool

    Trust All Tools active, confirmations are off · /quit to exit      <- trust modal suppressed
    firstmate · auto · ◔ 2% · Midway: 18h 28m                         <- per-task agent config loaded
    • 80235                                                            <- launch brief auto-submitted and answered
    busy record: v1 gen=... seq=3 state=idle source=kiro-hook event=stop
    <id>.turn-ended touched by the stop hook

## 3. Mid-turn, driven through the shipped read paths

    classify        : busy kiro-hook
    delivery guard  : MATCH   (fm_busy_lines_match kiro on the folded visible tail)
    busy record     : v1 gen=... seq=4 state=busy source=kiro-hook event=user-prompt-submit
    agent_state     : alive
    foreground grp  : /Users/marsjohn/.toolbox/bin/kiro-cli;aim;.../sandbox/launcher;...
    harness(ancestry, every foreground pid) : comm kiro
    pane_current_command : toolbox-exec        <- exactly why detection reads the foreground group

## 4. A real steer through fm-send.sh

    $ bin/fm-send.sh kiro-live-1 "Read your steering inbox and reply with exactly PONG."   -> exit 0
    worker: ● Shell ls -1 .../kiro-live-1.inbox/*.msg  ->  001.msg
    worker: ● Read .../001.msg  ->  "Read your steering inbox and reply with exactly PONG."
    worker: • Handled 001.msg (replied PONG) and moved it to the handled/ directory.
    composer row while working: ›  Kiro is working · Type to steer · Ctrl+S to queue
    busy record: seq=5 busy(user-prompt-submit) -> seq=6 idle(stop)

## 5. Interrupt and exit

    single Escape  -> ● Cancelled sleep 45 / ● Cancelled streaming, composer back to its placeholder,
                      busy record deliberately left busy (kiro's stop hook does not fire on Escape -
                      the disclosed, accepted gap)
    /quit          -> Session ended.
                      Resume with: kiro-cli --resume-id beb89cb5-a5d9-4fb8-bd64-e35e015df0aa
                      session file lives in <id>.kiro-home/sessions/cli/, absent from ~/.kiro

## 6. Composer verdicts, live pane, this change vs base da5e658

    state                              this change    base commit
    fresh idle placeholder             empty          pending
    mid-turn "Kiro is working" row     empty          pending
    real typed input                   pending        pending      <- never over-stripped

## 7. Adversarial refusals, real CLI

    --secondmate kiro
      error: kiro is a verified crewmate/scout adapter only and cannot run a secondmate; ...
    --model claude-nonexistent-9   (checked against the REAL kiro-cli --list-models)
      error: kiro model 'claude-nonexistent-9' is not listed by 'kiro-cli --list-models'; ...
    --model claude-sonnet-5 --effort xhigh   (real listed id)
      spawned; launch line carries --model 'claude-sonnet-5' --effort 'xhigh'
    state dir containing a space
      error: kiro hook scripts would live under '.../with space/kiro-ws-1.kiro-home', whose path
      contains whitespace; kiro hook commands must be a single unquoted token, ...
      (no pane, no worktree, no state written)

## 8. Teardown

    $ bin/fm-teardown.sh kiro-live-1 --force      -> exit 0
    teardown kiro-live-1 complete (...)
    per-task <id>.kiro-home REMOVED
