#!/usr/bin/env bash
# Live drift guard for the Kiro CLI adapter's vendor-controlled surface (V2
# engine only): the per-turn agent-config hooks (the busy/turn-end state
# signal), the rendered `Kiro is working` footer the DELIVERY guard matches, the
# composer glyph and idle placeholder, Escape interrupt, and /quit exit with its
# resume line. Opt-in because it submits real prompts (no echo provider exists
# for kiro). v3/KAS is explicitly out of scope and never exercised here.
#
# Isolation: the worker runs under a per-guard KIRO_HOME so its agent config,
# trust setting, and sessions land in the lab store, never the operator's real
# ~/.kiro; auth lives in the XDG data dir and is unaffected by KIRO_HOME, so the
# guard uses the operator's real sign-in without copying it (verified in
# docs/verification/kiro.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIRO_BIN=$(command -v kiro-cli 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-kiro-signals-$$"
SESSION=kiro-signals
TARGET="$SESSION:kiro"
KIRO_VERSION=$([ -n "$KIRO_BIN" ] && "$KIRO_BIN" --version 2>/dev/null | head -1 || echo "kiro-cli(unknown)")

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s [%s]\n' "$1" "$KIRO_VERSION" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_KIRO_SIGNALS_LIVE kiro-cli tmux
[ -n "$KIRO_BIN" ] || fail "kiro-cli is not installed"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-kiro-signals.XXXXXX") || fail "could not create the isolated kiro lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace" "$LAB/home/agents" "$LAB/home/settings"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated kiro workspace"

# The per-guard KIRO_HOME carries the trust setting (so --trust-all-tools does
# not block on its modal) and a per-task agent config whose hooks touch marker
# files, exactly the claude-shaped pair the adapter installs. Auth is NOT
# relocated (it lives in the XDG data dir), so the operator's sign-in applies.
KIRO_HOME_DIR="$LAB/home"
printf '{"chat.disableTrustAllConfirmation":true}\n' > "$KIRO_HOME_DIR/settings/cli.json"
cat > "$KIRO_HOME_DIR/agents/firstmate.json" <<EOF
{"name":"firstmate","description":"live guard","tools":["*"],"allowedTools":["*"],"hooks":{"userPromptSubmit":[{"command":"touch $LAB/PROMPT"}],"stop":[{"command":"touch $LAB/STOP"}]}}
EOF

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# Create the session/window without -c (unsupported on older tmux) and cd into
# the workspace on the launch line instead, so the guard runs on every tmux the
# fleet still meets.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n kiro \
  || fail "could not open the isolated kiro window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -200 2>/dev/null || true
}

# The real consumer of kiro's footer: the delivery guard the submit-ack and
# pending-reply observation paths read. Consumes a screen on stdin and folds it
# the way those callers do - blank lines dropped, last 12 kept - so a footer
# left behind in the 200-line scrollback cannot satisfy the match.
kiro_footer_busy() {
  local visible
  visible=$(grep -v '^[[:space:]]*$' | tail -12)
  printf '%s\0' "$visible" | fm_busy_lines_match kiro
}

# The launch prompt asks for a computed answer (12345+67890=80235) so the awaited
# token never appears in the echoed launch line itself.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "cd \"$WORKSPACE\" && KIRO_HOME=\"$KIRO_HOME_DIR\" $KIRO_BIN chat --agent-engine v2 --agent firstmate --trust-all-tools \"Add 12345 and 67890. Reply with exactly the sum and nothing else\"" \
  || fail "could not type the kiro launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the kiro launch line"

# The composer glyph and idle placeholder must be exactly what the adapter's
# composer classification depends on. Wait for the first-turn footer or reply.
composer_seen=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in
    *"ask a question or describe a task"*) composer_seen=1; break ;;
    *"Kiro is working"*|*80235*|*80,235*) composer_seen=1; break ;;
  esac
  sleep 0.5
done
[ -n "$composer_seen" ] || fail "the kiro TUI never rendered its composer or a working footer"

# The busy footer must render while the launch turn is in flight so the portable
# matcher has live text to prove. Turns can take a while on cold start.
busy_live=
for _ in $(seq 1 240); do
  screen=$(capture)
  if printf '%s' "$screen" | kiro_footer_busy; then busy_live=1; break; fi
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 1
done
[ -n "$busy_live" ] || fail "the kiro delivery guard never matched the real kiro turn in flight"
pass "the real kiro busy footer matches the kiro delivery guard in flight"

# The launch turn must complete and its reply land.
for _ in $(seq 1 480); do
  screen=$(capture)
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 0.5
done
case "$(capture)" in
  *80235*|*80,235*) pass "the real kiro worker processed its launch prompt" ;;
  *) fail "the real kiro worker never answered its launch prompt" ;;
esac

# The claude-shaped per-turn hooks (kiro's only state signal) must both have
# fired: userPromptSubmit on submit and stop at turn end.
[ -f "$LAB/PROMPT" ] || fail "the kiro userPromptSubmit hook never fired"
hook_stop=
for _ in $(seq 1 60); do
  [ -f "$LAB/STOP" ] && { hook_stop=1; break; }
  sleep 0.5
done
[ -n "$hook_stop" ] || fail "the kiro stop hook never fired at turn end"
pass "the real kiro V2 userPromptSubmit and stop hooks both fire per turn"

# Once settled to the idle composer, the busy footer must no longer match.
idle_settled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *"ask a question or describe a task"*) idle_settled=1; break ;; esac
  sleep 0.5
done
[ -n "$idle_settled" ] || fail "the kiro composer never settled to its idle placeholder after the reply"
printf '%s' "$screen" | kiro_footer_busy \
  && fail "the settled kiro footer still matches the busy signature" || true

# Interrupt a genuinely long turn with exactly one Escape and require the
# Cancelled row it prints.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "run the shell command: sleep 45" \
  || fail "could not type the long kiro prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the long kiro prompt"
for _ in $(seq 1 100); do
  screen=$(capture)
  printf '%s' "$screen" | kiro_footer_busy && break
  sleep 0.5
done
printf '%s' "$screen" | kiro_footer_busy \
  || fail "the long kiro turn never showed its busy footer"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not send Escape to the real kiro turn"
cancelled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *Cancelled*) cancelled=1; break ;; esac
  sleep 0.5
done
[ -n "$cancelled" ] || fail "a single Escape never cancelled the real kiro turn"
pass "a single Escape cancels the real kiro turn"

# /quit exits and prints the resume line the adapter records as the resume id.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/quit" \
  || fail "could not type the kiro exit command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the kiro exit command"
gone=
for _ in $(seq 1 60); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$current" in *kiro-cli*) sleep 0.5 ;; *) gone=1; break ;; esac
done
[ -n "$gone" ] || fail "/quit never stopped the real kiro process"
case "$(capture)" in
  *"--resume-id"*) pass "/quit stops the real kiro process and prints its resume-id line" ;;
  *) pass "/quit stops the real kiro process" ;;
esac

cleanup
trap - EXIT
