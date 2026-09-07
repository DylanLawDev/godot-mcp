extends "res://addons/godot_mcp/tests/test_case.gd"

const HttpServer = preload("res://addons/godot_mcp/http_server.gd")
const McpHandler = preload("res://addons/godot_mcp/mcp_handler.gd")

class CountingRegistry:
	extends RefCounted
	var calls := 0
	func list_tools() -> Array:
		return [{"name": "count", "description": "test", "inputSchema": {"type": "object"}}]
	func call_tool_async(_name: String, _arguments: Dictionary) -> Variant:
		calls += 1
		return {"isError": false, "content": [{"type": "text", "text": "ok"}]}

# Test dispatch: echoes a fixed JSON-RPC result for "ok" bodies; returns "" (notification) for "notify".
func _dispatch(body: String) -> String:
	if body == "notify":
		return ""
	return '{"jsonrpc":"2.0","id":1,"result":{"echo":%s}}' % JSON.stringify(body)

# Sends one raw HTTP request to the running server and returns the full raw HTTP response.
func _round_trip(port: int, raw_request: String) -> String:
	var client := StreamPeerTCP.new()
	assert_true(client.connect_to_host("127.0.0.1", port) == OK)
	var server: Variant = _server
	var got := ""
	var sent := false
	for i in range(400):
		server.poll()
		client.poll()
		if not sent and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			client.put_data(raw_request.to_utf8_buffer())
			sent = true
		var avail := client.get_available_bytes()
		if avail > 0:
			var chunk: Array = client.get_data(avail)
			got += PackedByteArray(chunk[1]).get_string_from_utf8()
			var split := got.find("\r\n\r\n")
			if split != -1:
				var head := got.substr(0, split)
				var length := 0
				for line in head.split("\r\n"):
					if line.to_lower().begins_with("content-length:"):
						length = int(line.substr(line.find(":") + 1).strip_edges())
				if got.substr(split + 4).to_utf8_buffer().size() >= length:
					break
		OS.delay_msec(2)
	return got

var _server

func _modern_body(method: String, params := {}, version := "2026-07-28") -> String:
	var p: Dictionary = params.duplicate(true)
	p["_meta"] = {
		"io.modelcontextprotocol/protocolVersion": version,
		"io.modelcontextprotocol/clientCapabilities": {},
	}
	return JSON.stringify({"jsonrpc": "2.0", "id": 7, "method": method, "params": p})

func _http_post(port: int, body: String, headers := []) -> String:
	var req := "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
	for header in headers:
		req += "%s\r\n" % header
	req += "Content-Length: %d\r\n\r\n%s" % [body.to_utf8_buffer().size(), body]
	return _round_trip(port, req)

func test_post_mcp_dispatches_and_responds_200() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch"))
	assert_eq(_server.start(0), OK)
	var port: int = _server.get_port()
	var body := "ok"
	var req := "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s" % [body.length(), body]
	var resp := _round_trip(port, req)
	assert_has(resp, "HTTP/1.1 200 OK")
	assert_has(resp, "application/json")
	assert_has(resp, '"echo"')
	_server.stop()

func test_notification_responds_202_empty() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch"))
	assert_eq(_server.start(0), OK)
	var port: int = _server.get_port()
	var body := "notify"
	var req := "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s" % [body.length(), body]
	var resp := _round_trip(port, req)
	assert_has(resp, "HTTP/1.1 202 Accepted")
	_server.stop()

func test_get_returns_405() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch"))
	assert_eq(_server.start(0), OK)
	var port: int = _server.get_port()
	var req := "GET /mcp HTTP/1.1\r\nHost: x\r\n\r\n"
	var resp := _round_trip(port, req)
	assert_has(resp, "HTTP/1.1 405 Method Not Allowed")
	_server.stop()

var _pending_response
func _dispatch_pending(body: String) -> Variant:
	if body == "later":
		_pending_response = preload("res://addons/godot_mcp/runtime/deferred_result.gd").new()
		return _pending_response
	return "{}"

func test_pending_request_does_not_block_other_client() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch_pending"))
	assert_eq(_server.start(0), OK)
	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", _server.get_port())
	var sent := false
	for _i in 100:
		_server.poll()
		client.poll()
		if not sent and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			client.put_data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nlater".to_utf8_buffer())
			sent = true
		if _pending_response != null:
			break
		OS.delay_msec(1)
	assert_true(_pending_response != null)
	var response := _round_trip(_server.get_port(), "POST /mcp HTTP/1.1\r\nContent-Length: 3\r\n\r\nnow")
	assert_has(response, "200 OK")
	assert_false(_pending_response.done)
	_pending_response.resolve('{"completed":true}')
	var output := ""
	for _i in 100:
		_server.poll()
		client.poll()
		if client.get_available_bytes() > 0:
			output += client.get_utf8_string(client.get_available_bytes())
		if output.contains('"completed"'):
			break
		OS.delay_msec(1)
	assert_has(output, '"completed":true')
	_server.stop()

func test_mcp_prefix_and_query_do_not_match_endpoint() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch"))
	assert_eq(_server.start(0), OK)
	var port: int = _server.get_port()
	for path in ["/mcp-extra", "/mcp?x=1"]:
		var req := "POST %s HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n" % path
		assert_has(_round_trip(port, req), "HTTP/1.1 404 Not Found")
	_server.stop()

func test_delete_returns_405() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch"))
	assert_eq(_server.start(0), OK)
	var req := "DELETE /mcp HTTP/1.1\r\nHost: x\r\n\r\n"
	assert_has(_round_trip(_server.get_port(), req), "HTTP/1.1 405 Method Not Allowed")
	_server.stop()

func test_fragmented_utf8_body_and_response_are_complete() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch"))
	assert_eq(_server.start(0), OK)
	var body := "héllo 世界"
	var req := "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s" % [body.to_utf8_buffer().size(), body]
	var response := _round_trip(_server.get_port(), req)
	assert_has(response, body)
	_server.stop()

func test_modern_headers_are_checked_before_tool_dispatch() -> void:
	var registry := CountingRegistry.new()
	var handler := McpHandler.new(registry, null, true)
	_server = HttpServer.new(Callable(handler, "handle_request"))
	assert_eq(_server.start(0), OK)
	var body := _modern_body("tools/call", {"name": "count", "arguments": {}})
	var missing := _http_post(_server.get_port(), body)
	assert_has(missing, "HTTP/1.1 400 Bad Request")
	assert_has(missing, '"code":-32020')
	assert_eq(registry.calls, 0)
	var mismatch := _http_post(_server.get_port(), body, ["MCP-Protocol-Version: 2026-07-28", "Mcp-Method: tools/list", "Mcp-Name: count"])
	assert_has(mismatch, "HTTP/1.1 400 Bad Request")
	assert_eq(registry.calls, 0)
	var legacy_shape := '{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}'
	var no_meta := _http_post(_server.get_port(), legacy_shape, ["MCP-Protocol-Version: 2026-07-28", "Mcp-Method: tools/list"])
	assert_has(no_meta, "HTTP/1.1 400 Bad Request")
	assert_has(no_meta, '"code":-32602')
	assert_eq(registry.calls, 0)
	var good := _http_post(_server.get_port(), body, ["MCP-Protocol-Version: 2026-07-28", "Mcp-Method: tools/call", "Mcp-Name: count"])
	assert_has(good, "HTTP/1.1 200 OK")
	assert_eq(registry.calls, 1)
	_server.stop()

func test_modern_encoded_resource_name_matches_and_malformed_base64_fails() -> void:
	var handler := McpHandler.new(null, null, true)
	_server = HttpServer.new(Callable(handler, "handle_request"))
	assert_eq(_server.start(0), OK)
	var uri := "godot://project/info"
	var body := _modern_body("resources/read", {"uri": uri})
	var encoded := "=?base64?%s?=" % Marshalls.utf8_to_base64(uri)
	var good := _http_post(_server.get_port(), body, ["MCP-Protocol-Version: 2026-07-28", "Mcp-Method: resources/read", "Mcp-Name: " + encoded])
	assert_has(good, "HTTP/1.1 200 OK")
	var bad := _http_post(_server.get_port(), body, ["MCP-Protocol-Version: 2026-07-28", "Mcp-Method: resources/read", "Mcp-Name: =?base64?%%%?="])
	assert_has(bad, "HTTP/1.1 400 Bad Request")
	assert_has(bad, '"code":-32020')
	_server.stop()

func test_modern_unknown_method_is_404_and_unsupported_version_is_400() -> void:
	var handler := McpHandler.new(null, null, true)
	_server = HttpServer.new(Callable(handler, "handle_request"))
	assert_eq(_server.start(0), OK)
	var unknown := _modern_body("optional/not-supported")
	var unknown_response := _http_post(_server.get_port(), unknown, ["MCP-Protocol-Version: 2026-07-28", "Mcp-Method: optional/not-supported"])
	assert_has(unknown_response, "HTTP/1.1 404 Not Found")
	assert_has(unknown_response, '"code":-32601')
	var unsupported := _modern_body("tools/list", {}, "2099-01-01")
	var unsupported_response := _http_post(_server.get_port(), unsupported, ["MCP-Protocol-Version: 2099-01-01", "Mcp-Method: tools/list"])
	assert_has(unsupported_response, "HTTP/1.1 400 Bad Request")
	assert_has(unsupported_response, '"code":-32022')
	_server.stop()

func test_legacy_initialize_and_tool_calls_need_no_modern_headers() -> void:
	var handler := McpHandler.new(null, null, true)
	_server = HttpServer.new(Callable(handler, "handle_request"))
	assert_eq(_server.start(0), OK)
	var initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
	assert_has(_http_post(_server.get_port(), initialize), "HTTP/1.1 200 OK")
	var list := '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
	assert_has(_http_post(_server.get_port(), list), "HTTP/1.1 200 OK")
	_server.stop()
