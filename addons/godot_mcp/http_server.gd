@tool
extends RefCounted

const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
const Http = preload("res://addons/godot_mcp/http_message.gd")

var _tcp := TCPServer.new()
var _dispatch: Callable               # (body[, context]) -> String | {status, body, content_type} | Deferred
var _clients: Dictionary = {}         # id -> {peer: StreamPeerTCP, buf: PackedByteArray}
var _next_id := 0

func _init(dispatch: Callable) -> void:
	_dispatch = dispatch

func start(port: int) -> int:
	return _tcp.listen(port, "127.0.0.1")

func get_port() -> int:
	return _tcp.get_local_port()

func is_listening() -> bool:
	return _tcp.is_listening()

func stop() -> void:
	for id in _clients:
		var c = _clients[id]
		if c.has("pending"):
			c.pending.cancel("HTTP server stopped")
		if c["peer"] != null:
			c["peer"].disconnect_from_host()
	_clients.clear()
	if _tcp.is_listening():
		_tcp.stop()

# Call every frame (editor _process) or busy-loop (tests).
func poll() -> void:
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		_clients[_next_id] = {"peer": peer, "buf": PackedByteArray()}
		_next_id += 1
	var done := []
	for id in _clients:
		if _service_client(id):
			done.append(id)
	for id in done:
		_clients.erase(id)

# Returns true when the client is finished and should be removed.
func _service_client(id: int) -> bool:
	var c = _clients[id]
	var peer: StreamPeerTCP = c["peer"]
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		if c.has("pending"):
			c.pending.cancel("HTTP client disconnected")
		return true
	if c.has("out"):
		var chunk: PackedByteArray = c.out.slice(c.offset, mini(c.offset + 65536, c.out.size()))
		var sent := peer.put_partial_data(chunk)
		if sent[0] != OK:
			peer.disconnect_from_host()
			return true
		c.offset += sent[1]
		if c.offset >= c.out.size():
			peer.disconnect_from_host()
			return true
		return false
	if c.has("pending"):
		c.pending.poll()
		if c.pending.done:
			_send_result(c, c.pending.value)
			c.erase("pending")
			return false
		return false
	var avail := peer.get_available_bytes()
	if avail > 0:
		var chunk: Array = peer.get_data(avail)
		c["buf"].append_array(chunk[1])
	var raw: String = c["buf"].get_string_from_utf8()
	var body_start := Http.header_end(raw)
	if body_start == -1:
		return false  # headers not complete yet
	var parsed := Http.parse_request(raw)
	if not parsed["ok"]:
		_send(c, Http.build_response(400, "Bad Request", "text/plain"))
		return false
	var need := Http.content_length(parsed["headers"])
	var byte_body_start := _header_end_bytes(c["buf"])
	if byte_body_start == -1 or c["buf"].size() - byte_body_start < need:
		return false  # body still arriving
	parsed["body"] = c["buf"].slice(byte_body_start, byte_body_start + need).get_string_from_utf8()
	return _respond(peer, parsed, c)

func _header_end_bytes(bytes: PackedByteArray) -> int:
	for i in range(0, bytes.size() - 3):
		if bytes[i] == 13 and bytes[i + 1] == 10 and bytes[i + 2] == 13 and bytes[i + 3] == 10:
			return i + 4
	return -1

func _respond(peer: StreamPeerTCP, parsed: Dictionary, client: Dictionary) -> bool:
	var origin_check := _validate_origin(parsed.get("header_values", {}))
	if not origin_check["ok"]:
		_send(client, Http.build_response(403, JSON.stringify({
			"jsonrpc": "2.0", "error": {"code": -32600, "message": origin_check["message"]},
		})))
		return false
	if parsed["path"] != "/mcp":
		_send(client, Http.build_response(404, "Not Found", "text/plain"))
		return false
	if parsed["method"] != "POST":
		_send(client, Http.build_response(405, "Method Not Allowed", "text/plain"))
		return false
	var context := {
		"headers": parsed["headers"],
		"header_values": parsed["header_values"],
		"method": parsed["method"],
		"path": parsed["path"],
		"listening_port": get_port(),
	}
	var out = _dispatch.call(parsed["body"], context) if _dispatch.get_argument_count() >= 2 else _dispatch.call(parsed["body"])
	if out is Deferred:
		client["pending"] = out
		return false
	_send_result(client, out)
	return false

# Accepts the structured {status, body, content_type} shape, a serialized
# response body String, or "" for an accepted notification.
func _send_result(client: Dictionary, out: Variant) -> void:
	if typeof(out) == TYPE_DICTIONARY:
		_send(client, Http.build_response(int(out.get("status", 200)), str(out.get("body", "")), str(out.get("content_type", "application/json"))))
	elif str(out) == "":
		_send(client, Http.build_response(202, ""))
	else:
		_send(client, Http.build_response(200, str(out)))

func _validate_origin(header_values: Dictionary) -> Dictionary:
	if not header_values.has("origin"):
		return {"ok": true}
	var origins = header_values["origin"]
	if typeof(origins) != TYPE_ARRAY or origins.size() != 1:
		return {"ok": false, "message": "Forbidden Origin: exactly one Origin value is required"}
	var origin: String = origins[0]
	var pattern := RegEx.new()
	pattern.compile("^http://(127\\.0\\.0\\.1|localhost):([0-9]{1,5})$")
	var match := pattern.search(origin)
	if match == null or int(match.get_string(2)) != get_port():
		return {"ok": false, "message": "Forbidden Origin: only the loopback MCP endpoint is allowed"}
	return {"ok": true}

func _send(client: Dictionary, response_text: String) -> void:
	client["out"] = response_text.to_utf8_buffer()
	client["offset"] = 0
