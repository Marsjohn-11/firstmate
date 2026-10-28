#!/usr/bin/env bash
# tests/fm-builder-mcp-call.test.sh - behavior tests for bin/fm-builder-mcp-call.sh.
#
# The server is a fakebin stand-in selected through FM_BUILDER_MCP_BIN. It reads
# JSON-RPC lines on stdin, answers initialize, and answers the tools/call with
# the reply named by FAKE_MODE, so no test starts the real builder-mcp.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CALL="$ROOT/bin/fm-builder-mcp-call.sh"
TMP_ROOT=$(fm_test_tmproot fm-builder-mcp-call-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SERVER="$FAKEBIN/builder-mcp"

cat > "$SERVER" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$0")
printf '%s\n' "$@" > "$dir/args"
[ "${FAKE_MODE:-}" = exit ] && { echo "Midway session expired" >&2; exit 1; }
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$dir/requests"
  id=$(printf '%s' "$line" | jq -r '.id // empty')
  case "$id" in
    1) jq -cn '{jsonrpc: "2.0", id: 1, result: {capabilities: {}}}' ;;
    2)
      # A log notification and a split write precede the answer, so the
      # client must wait for a complete id 2 line.
      jq -cn '{jsonrpc: "2.0", method: "notifications/message", params: {data: "working"}}'
      case "${FAKE_MODE:-ok}" in
        ok) printf '{"jsonrpc":"2.0","id":2,'; sleep 0.3
            printf '"result":{"content":[{"type":"text","text":"{\\"content\\":{\\"data\\":1}}"}]}}\n' ;;
        tool-error) jq -cn '{jsonrpc: "2.0", id: 2, result: {isError: true,
                      content: [{type: "text", text: "pipeline not found"}]}}' ;;
        rpc-error) jq -cn '{jsonrpc: "2.0", id: 2, error: {code: -32602, message: "Unknown tool"}}' ;;
      esac
      ;;
  esac
done
SH
chmod +x "$SERVER"

call() {
  FM_BUILDER_MCP_BIN="$SERVER" "$CALL" "$@"
}

test_result_text_is_printed() {
  local out status=0
  rm -f "$FAKEBIN/requests"
  out=$(call GetPipelineDetails '{"pipelineName":"P"}' 2>&1) || status=$?
  expect_code 0 "$status" "a successful call"
  assert_equals '{"content":{"data":1}}' "$out" "the tool's text result should be printed alone"
  assert_equals $'--include-tools\nGetPipelineDetails' "$(cat "$FAKEBIN/args")" \
    "the server should be limited to the called tool"
  assert_equals '{"name":"GetPipelineDetails","arguments":{"pipelineName":"P"}}' \
    "$(jq -c 'select(.id == 2) | .params' "$FAKEBIN/requests")" "the call should carry the tool and its arguments"
  pass "a call prints the tool's text result once the full reply arrives"
}

test_tool_error_exits_1_with_its_text() {
  local out status=0
  out=$(FAKE_MODE=tool-error call GetPipelineDetails '{}' 2>/dev/null) || status=$?
  expect_code 1 "$status" "an isError result"
  assert_equals "pipeline not found" "$out" "an isError result should still print its text"
  pass "an isError result exits 1 and prints its text"
}

test_rpc_error_exits_1_on_stderr() {
  local out err status=0
  err="$TMP_ROOT/rpc.err"
  out=$(FAKE_MODE=rpc-error call GetPipelineDetails '{}' 2>"$err") || status=$?
  expect_code 1 "$status" "a JSON-RPC error"
  assert_equals "" "$out" "a JSON-RPC error should print nothing on stdout"
  assert_contains "$(cat "$err")" "Unknown tool" "the JSON-RPC error message should reach stderr"
  pass "a JSON-RPC error exits 1 with its message on stderr"
}

test_server_exit_before_answer_exits_3() {
  local err status=0
  err="$TMP_ROOT/exit.err"
  FAKE_MODE='exit' call GetPipelineDetails '{}' >/dev/null 2>"$err" || status=$?
  expect_code 3 "$status" "a server that exits before answering"
  assert_contains "$(cat "$err")" "Midway session expired" "the server's first stderr line should be reported"
  pass "a server that exits before answering exits 3 naming why"
}

test_missing_server_and_usage() {
  local status=0 out
  out=$(FM_BUILDER_MCP_BIN="$TMP_ROOT/absent" "$CALL" GetPipelineDetails '{}' 2>&1) || status=$?
  expect_code 3 "$status" "a missing builder-mcp"
  assert_contains "$out" "builder-mcp not found at $TMP_ROOT/absent" "a missing server should name the path"
  status=0
  call GetPipelineDetails >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a call without arguments"
  status=0
  call 'Bad Tool' '{}' >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an invalid tool name"
  status=0
  call GetPipelineDetails '[1]' >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "non-object arguments"
  pass "a missing server exits 3 and bad usage exits 2"
}

test_result_text_is_printed
test_tool_error_exits_1_with_its_text
test_rpc_error_exits_1_on_stderr
test_server_exit_before_answer_exits_3
test_missing_server_and_usage
