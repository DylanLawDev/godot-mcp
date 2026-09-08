extends "res://addons/godot_mcp/tests/test_case.gd"

const HttpServer = preload("res://addons/godot_mcp/http_server.gd")

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
			if got.find("\r\n\r\n") != -1:
				break
		OS.delay_msec(2)
	return got

var _server

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
