extends Node
const Peer = preload("res://addons/godot_mcp/runtime/bridge_peer.gd")
const Wire = preload("res://addons/godot_mcp/runtime/bridge_wire.gd")
const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
var scene_ready := false
var session_id := ""
var logger
var handlers: Dictionary = {}
var _peer := Peer.new()
var _wire := Wire.new()
var _token := ""
var _hello := false
var _accepted := false
var _ready_sent := false
var _heartbeat := 0
var _deadline := 0
var _tasks: Dictionary = {}
var _quitting := false

func configure(args: Dictionary, capture) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	session_id = str(args["--mcp-session"])
	_token = str(args["--mcp-token"])
	logger = capture
	_peer.connect_to_host("127.0.0.1", int(args["--mcp-port"]))
	_deadline = Time.get_ticks_msec() + 15000

func _process(_delta: float) -> void:
	_peer.poll()
	if _quitting:
		if _peer.pending_bytes() == 0 or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			get_tree().quit()
		return
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		if _accepted or Time.get_ticks_msec() >= _deadline:
			_cleanup()
			get_tree().quit(2)
		return
	if not _hello:
		_send({"kind": "hello", "version": 1, "token": _token})
		_hello = true
	var available := _peer.get_available_bytes()
	if available > 0:
		var read := _peer.get_data(mini(available, 65536))
		if read[0] == OK:
			for message in _wire.feed(read[1]):
				_receive(message)
				if _quitting:
					break
		if _wire.error != "":
			_peer.disconnect_from_host()
			return
	if _quitting or not _accepted:
		return
	if scene_ready and not _ready_sent:
		_send({"kind": "ready", "capabilities": {"rendering": DisplayServer.get_name() != "headless", "commands": handlers.keys()}})
		_ready_sent = true
	if Time.get_ticks_msec() - _heartbeat >= 1000:
		_send({"kind": "heartbeat"})
		_heartbeat = Time.get_ticks_msec()
	for id in _tasks.keys():
		var task = _tasks[id]
		task.poll()
		if task.done:
			_reply(id, task.value)
			_tasks.erase(id)

func _receive(message: Dictionary) -> void:
	if _quitting:
		return
	if message.get("session_id") != session_id:
		_peer.disconnect_from_host()
		return
	if not _accepted:
		_accepted = message.get("kind") == "accepted" and message.get("version") == 1
		if not _accepted:
			_peer.disconnect_from_host()
		return
	var id := str(message.get("request_id", ""))
	var command := str(message.get("command", ""))
	if command == "cancel":
		if _tasks.has(id):
			_tasks[id].cancel()
		return
	if id == "" or _tasks.has(id) or not message.get("args") is Dictionary:
		_peer.disconnect_from_host()
		return
	if command == "quit":
		_cleanup()
		if _reply(id, {"ok": true, "value": {"stopping": true}}):
			_peer.prioritize_last_frame()
		_quitting = true
	elif not handlers.has(command):
		_reply(id, {"ok": false, "error": "Unknown runtime command: " + command})
	elif _tasks.size() >= 64:
		_reply(id, {"ok": false, "error": "Too many pending runtime commands"})
	else:
		var result: Variant = handlers[command].call(message.args)
		if result is Deferred:
			_tasks[id] = result
		else:
			_reply(id, result)

func _reply(id: String, result: Variant) -> bool:
	if _send({"kind": "reply", "request_id": id, "result": result}):
		return true
	if _send({"kind": "reply", "request_id": id, "result": {"ok": false, "error": "Runtime response too large or write queue full; reduce requested data"}}):
		return true
	# Never silently drop a completed request when even its error cannot queue.
	# Disconnect makes every outstanding manager request fail immediately.
	_peer.disconnect_from_host()
	return false

func _send(message: Dictionary) -> bool:
	message["session_id"] = session_id
	var bytes := Wire.encode(message)
	return not bytes.is_empty() and _peer.put_data(bytes) == OK

func _cleanup() -> void:
	for task in _tasks.values():
		task.cancel("Runtime stopped")
	_tasks.clear()

func _exit_tree() -> void:
	_cleanup()
	_peer.disconnect_from_host()
