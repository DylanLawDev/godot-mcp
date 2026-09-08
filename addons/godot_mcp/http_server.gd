@tool
extends RefCounted

const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
const Http = preload("res://addons/godot_mcp/http_message.gd")

var _tcp := TCPServer.new()
var _dispatch: Callable               # (body: String) -> String  ("" => notification, 202 no body)
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
			_send(c, Http.build_response(200, str(c.pending.value)))
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
	if parsed["body"].to_utf8_buffer().size() < need:
		return false  # body still arriving
	return _respond(peer, parsed, c)

func _respond(peer: StreamPeerTCP, parsed: Dictionary, client: Dictionary) -> bool:
	if parsed["method"] != "POST" or not str(parsed["path"]).begins_with("/mcp"):
		_send(client, Http.build_response(405, "Method Not Allowed", "text/plain"))
		return false
	var out: Variant = _dispatch.call(parsed["body"])
	if out is Deferred:
		client["pending"] = out
		return false
	if out == "":
		_send(client, Http.build_response(202, ""))
	else:
		_send(client, Http.build_response(200, out))
	return false

func _send(client: Dictionary, response_text: String) -> void:
	client["out"] = response_text.to_utf8_buffer()
	client["offset"] = 0
