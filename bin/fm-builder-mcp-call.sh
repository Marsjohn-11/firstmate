#!/usr/bin/env bash
# fm-builder-mcp-call.sh - call one builder-mcp tool from a shell and print its result.
#
# Usage:
#   fm-builder-mcp-call.sh <tool> <arguments-json>
#
# Starts builder-mcp as a stdio MCP server limited to <tool>, sends initialize and
# one tools/call, and prints the text content of the call's result on stdout,
# which for builder-mcp tools is the tool's JSON body ({"content": ...}).
# Authentication is builder-mcp's own Midway session, so an expired session
# surfaces here as a failed call rather than as a prompt.
#
# Exit status:
#   0  the tool returned a result that is not flagged isError
#   1  the tool flagged isError (its text is still printed), or the server
#      answered with a JSON-RPC error (printed on stderr)
#   2  usage error
#   3  builder-mcp is not installed, or exited before answering
#
# The call itself is not bounded; run it under fm_run_timed when a deadline
# matters. A bounded TERM stops the server too.
#
# Environment:
#   FM_BUILDER_MCP_BIN  builder-mcp path (default: builder-mcp on PATH, then
#                       ~/.toolbox/bin/builder-mcp)
set -u

die_usage() {
  echo "usage: fm-builder-mcp-call.sh <tool> <arguments-json>" >&2
  exit 2
}

[ "$#" -eq 2 ] || die_usage
TOOL=$1
ARGS=$2
case "$TOOL" in
  ''|*[!A-Za-z0-9_]*) die_usage ;;
esac
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 3; }
printf '%s' "$ARGS" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || { echo "error: arguments must be a JSON object" >&2; exit 2; }

BIN=${FM_BUILDER_MCP_BIN:-}
if [ -z "$BIN" ]; then
  BIN=$(command -v builder-mcp 2>/dev/null) || BIN="$HOME/.toolbox/bin/builder-mcp"
fi
[ -x "$BIN" ] || { echo "error: builder-mcp not found at $BIN (set FM_BUILDER_MCP_BIN)" >&2; exit 3; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-builder-mcp.XXXXXX") || exit 3
SERVER=
# shellcheck disable=SC2329  # Registered by the EXIT trap.
cleanup() {
  exec 3>&-
  if [ -n "$SERVER" ]; then
    kill "$SERVER" 2>/dev/null
    wait "$SERVER" 2>/dev/null
  fi
  rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

mkfifo "$WORK/in" || exit 3
"$BIN" --include-tools "$TOOL" < "$WORK/in" > "$WORK/out" 2> "$WORK/err" &
SERVER=$!
exec 3> "$WORK/in"

jq -cn '{jsonrpc: "2.0", id: 1, method: "initialize",
  params: {protocolVersion: "2025-06-18", capabilities: {},
    clientInfo: {name: "firstmate", version: "1"}}}' >&3
jq -cn '{jsonrpc: "2.0", method: "notifications/initialized"}' >&3
jq -cn --arg tool "$TOOL" --argjson args "$ARGS" \
  '{jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: $tool, arguments: $args}}' >&3

# reply: the server's complete answer to request 2, or nothing yet. A partial
# last line is skipped until the server finishes writing it.
reply() {
  jq -cR 'fromjson? | select(type == "object" and .id == 2)' "$WORK/out" 2>/dev/null | head -n 1
}

RESPONSE=
while :; do
  RESPONSE=$(reply)
  [ -n "$RESPONSE" ] && break
  if ! kill -0 "$SERVER" 2>/dev/null; then
    RESPONSE=$(reply)
    [ -n "$RESPONSE" ] && break
    first=$(sed -n '/[^[:space:]]/{p;q;}' "$WORK/err" | cut -c1-200)
    echo "error: builder-mcp exited before answering${first:+: $first}" >&2
    exit 3
  fi
  sleep 0.2
done

if printf '%s' "$RESPONSE" | jq -e 'has("error")' >/dev/null; then
  printf '%s' "$RESPONSE" | jq -r '"error: builder-mcp: " + (.error.message // (.error | tostring))' >&2
  exit 1
fi
printf '%s' "$RESPONSE" | jq -r '[.result.content[]? | select(.type == "text") | .text] | join("\n")'
printf '%s' "$RESPONSE" | jq -e '.result.isError == true' >/dev/null && exit 1
exit 0
