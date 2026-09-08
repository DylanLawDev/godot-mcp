@tool
extends RefCounted
const Peer = preload("res://addons/godot_mcp/runtime/bridge_peer.gd")
const Wire = preload("res://addons/godot_mcp/runtime/bridge_wire.gd")
const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
const BuildPipeline = preload("res://addons/godot_mcp/runtime/build_pipeline.gd")
var build_jobs
const Jobs = preload("res://addons/godot_mcp/runtime/process_jobs.gd")
var jobs
var sessions: Dictionary = {}
var active_id := ""
var latest_id := ""
var background_id := ""
var _listener := TCPServer.new()
var _peers: Array = []
var _pending: Dictionary = {}
var _stops: Dictionary = {}
var _next_request := 0
var _history: Array[String] = []

func _init(process_jobs = null) -> void:
	jobs = process_jobs if process_jobs != null else Jobs.new()
	build_jobs = BuildPipeline.new(self)

static func new_id() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()

static func artifact_dir(id: String) -> String:
	return ProjectSettings.globalize_path("user://godot_mcp/" + id)

func launch(scene: String, headless: bool, timeout_seconds: float = 15.0) -> Dictionary:
	if active_id != "":
		return {"ok": false, "error": "An interactive session is already active: " + active_id}
	if not _listener.is_listening():
		var err := _listener.listen(0, "127.0.0.1")
		if err != OK:
			return {"ok": false, "error": "Could not listen for runtime bridge"}
	var id := new_id()
	var token := new_id()
	var directory := artifact_dir(id)
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return {"ok": false, "error": "Could not create runtime artifact directory"}
	var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://")])
	if headless:
		args.append("--headless")
	args.append_array(PackedStringArray(["--script", "res://addons/godot_mcp/runtime/game_bootstrap.gd", "--", "--mcp-port", str(_listener.get_local_port()), "--mcp-token", token, "--mcp-session", id, "--mcp-scene", scene]))
	var spawned: Dictionary = jobs.launch(id, OS.get_executable_path(), args, "interactive")
	if not spawned.ok:
		return spawned
	active_id = id
	latest_id = id
	sessions[id] = {"session_id": id, "state": "starting", "scene": scene, "pid": spawned.value.pid, "headless": headless, "bridge_connected": false, "capabilities": {}, "started_at": spawned.value.started_at, "ended_at": null, "exit_code": null, "termination_reason": "", "diagnostics": [], "artifact_dir": directory, "_token": token, "_deadline": Time.get_ticks_msec() + int(timeout_seconds * 1000), "_peer": null, "_heartbeat": 0, "_errors": [], "_error_sequence": 0, "_stderr_sequence": 0, "_source_gap": false}
	return {"ok": true, "value": summary(id)}

func summary(id: String) -> Dictionary:
	if not sessions.has(id):
		return {}
	var out: Dictionary = sessions[id].duplicate(true)
	for key in out.keys():
		if str(key).begins_with("_"):
			out.erase(key)
	out["active_session_id"] = active_id if active_id != "" else null
	return out

func request(id: String, command: String, args: Dictionary, timeout_seconds: float = 10.0):
	var task := Deferred.new(timeout_seconds)
	if not sessions.has(id) or not sessions[id].bridge_connected:
		task.resolve({"ok": false, "error": "Session bridge is not connected: " + id})
		return task
	if _pending.size() >= 64:
		task.resolve({"ok": false, "error": "Too many pending runtime commands"})
		return task
	_next_request += 1
	var rid := str(_next_request)
	_pending[rid] = {"session_id": id, "task": task, "command": command, "samples": []}
	task.on_cancel = func(): _cancel_request(rid, id)
	if not _send(sessions[id]._peer, {"request_id": rid, "session_id": id, "command": command, "args": args}):
		task.cancel("Could not send runtime command (disconnected or payload too large)")
	return task

func _cancel_request(rid: String, id: String) -> void:
	if _pending.has(rid) and not _pending[rid].samples.is_empty():
		_pending[rid].task.resolve({"ok": false, "error": JSON.stringify({"message": "Performance sampling interrupted by cancellation, timeout, or bridge disconnect", "session_id": id, "partial": true, "samples": _pending[rid].samples})})
	_pending.erase(rid)
	if sessions.has(id):
		_send(sessions[id]._peer, {"session_id": id, "command": "cancel", "request_id": rid, "args": {}})

func _send(peer, message: Dictionary) -> bool:
	if peer == null:
		return false
	var frame := Wire.encode(message)
	return not frame.is_empty() and peer.put_data(frame) == OK

func poll() -> void:
	jobs.poll()
	build_jobs.poll()
	if background_id != "" and jobs.active(background_id):
		if Time.get_ticks_msec() >= jobs.records[background_id].get("deadline_msec", 9223372036854775807):
			jobs.terminate(background_id, "timeout")
	while _listener.is_connection_available():
		var peer := Peer.new(_listener.take_connection())
		if _peers.size() >= 8:
			peer.disconnect_from_host()
		else:
			_peers.append({"peer": peer, "wire": Wire.new(), "id": "", "deadline": Time.get_ticks_msec() + 5000})
	for item in _peers.duplicate():
		var peer = item.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or (item.id == "" and Time.get_ticks_msec() >= item.deadline):
			_drop(item)
			continue
		var available: int = peer.get_available_bytes()
		if available > 0:
			var read: Array = peer.get_data(mini(available, 65536))
			if read[0] != OK:
				_drop(item)
				continue
			_note_activity(item, read[1].size())
			for message in item.wire.feed(read[1]):
				_receive(item, message)
				if item.get("_dropped", false):
					break
			if item.wire.error != "":
				_drop(item)
	for rid in _pending.keys():
		if _pending.has(rid):
			_pending[rid].task.poll()
			if _pending.has(rid) and _pending[rid].task.done:
				_pending.erase(rid)
	if active_id != "":
		var s: Dictionary = sessions[active_id]
		var process: Dictionary = jobs.records.get(active_id, {})
		s.diagnostics = process.get("output", []).duplicate(true)
		if not s.diagnostics.is_empty() and s._stderr_sequence < int(s.diagnostics[0].sequence) - 1:
			s._source_gap = true
		for entry in s.diagnostics:
			if entry.sequence > s._stderr_sequence and entry.source == "stderr":
				var error_entry: Dictionary = entry.duplicate(true)
				error_entry["possible_duplicate"] = true
				_record_error(active_id, error_entry)
			if entry.sequence > s._stderr_sequence:
				s._stderr_sequence = entry.sequence
		if s.state == "starting" and Time.get_ticks_msec() >= s._deadline:
			s.termination_reason = "startup_timeout"
			jobs.terminate(active_id, "startup_timeout")
		if s.bridge_connected and Time.get_ticks_msec() - s._heartbeat > 5000:
			s.bridge_connected = false
		if not jobs.active(active_id):
			s.state = "failed" if s.termination_reason == "startup_timeout" else process.get("state", "failed")
			s.exit_code = process.get("exit_code")
			s.ended_at = process.get("ended_at")
			s.bridge_connected = false
			if s.termination_reason == "":
				s.termination_reason = process.get("termination_reason", "process_exit")
			for item in _peers.duplicate():
				if item.id == active_id:
					_drop(item)
			_history.append(active_id)
			active_id = ""
			while _history.size() > 20:
				sessions.erase(_history.pop_front())

	_poll_stops()

func _receive(item: Dictionary, message: Dictionary) -> void:
	if item.get("_dropped", false):
		return
	var id: String = item.id
	if id == "":
		id = str(message.get("session_id", ""))
		if id != active_id or not sessions.has(id) or message.get("version") != 1 or message.get("token") != sessions[id]._token or sessions[id]._peer != null or message.get("kind") != "hello":
			_drop(item)
			return
		item.id = id
		sessions[id]._peer = item.peer
		sessions[id]._heartbeat = Time.get_ticks_msec()
		_send(item.peer, {"kind": "accepted", "version": 1, "session_id": id})
		return
	if message.get("session_id") != id:
		_drop(item)
		return
	var s: Dictionary = sessions[id]
	match message.get("kind", ""):
		"ready":
			s.state = "stopping" if _stops.has(id) else "running"
			s.bridge_connected = true
			s.capabilities = message.get("capabilities", {})
			s._heartbeat = Time.get_ticks_msec()
		"heartbeat":
			s._heartbeat = Time.get_ticks_msec()
			s.bridge_connected = s.state in ["running", "stopping"]
		"errors":
			var batch: Variant = message.get("batch")
			if not batch is Dictionary or not batch.get("entries") is Array or batch.entries.size() > 100:
				_drop(item)
				return
			for entry in batch.entries:
				if not entry is Dictionary:
					_drop(item)
					return
				var error_entry: Dictionary = entry.duplicate(true)
				error_entry["source"] = "runtime_logger"
				_record_error(id, error_entry)
			s._source_gap = s._source_gap or batch.get("truncated", false)
		"progress":
			var rid := str(message.get("request_id", ""))
			if _pending.has(rid) and _pending[rid].session_id == id and _pending[rid].command == "sample_performance":
				if message.get("sample") is Dictionary and _pending[rid].samples.size() < 2000:
					_pending[rid].samples.append(message.sample)
		"reply":
			var rid := str(message.get("request_id", ""))
			if _pending.has(rid) and _pending[rid].session_id == id:
				var result: Variant = message.get("result")
				if not result is Dictionary or not result.get("ok") is bool:
					_drop(item)
					return
				_pending[rid].task.resolve(result)
				_pending.erase(rid)
		_:
			_drop(item)

func _drop(item: Dictionary) -> void:
	if item.get("_dropped", false):
		return
	item["_dropped"] = true
	item.peer.disconnect_from_host()
	_peers.erase(item)
	var id: String = item.id
	if id != "" and sessions.has(id):
		sessions[id].bridge_connected = false
		sessions[id]._peer = null
		if _stops.has(id):
			_stops[id].quit_sent = false
		for rid in _pending.keys():
			if _pending.has(rid) and _pending[rid].session_id == id:
				_pending[rid].task.cancel("Runtime bridge disconnected")

func shutdown() -> void:
	build_jobs.shutdown()
	for item in _peers.duplicate():
		_drop(item)
	_listener.stop()
	jobs.shutdown()
	for stop in _stops.values():
		stop.task.cancel("Plugin disabled")
	_stops.clear()

# Shared background lane for scenario/validation/export tools. Arguments are
# constructed by trusted tool code, never an arbitrary caller-provided command.
func launch_job(kind: String, arguments: PackedStringArray, timeout_seconds: float, prepared_id: String = "") -> Dictionary:
	if background_busy():
		return {"ok": false, "error": "A background job is active: " + background_id}
	var id := new_id() if prepared_id == "" else prepared_id
	if id.length() != 32 or not id.is_valid_hex_number(false) or jobs.records.has(id):
		return {"ok": false, "error": "Invalid or reused prepared job ID"}
	if DirAccess.make_dir_recursive_absolute(artifact_dir(id)) != OK:
		return {"ok": false, "error": "Could not create job artifact directory"}
	var result: Dictionary = jobs.launch(id, OS.get_executable_path(), arguments, kind)
	if result.ok:
		background_id = id
		jobs.records[id]["deadline_msec"] = Time.get_ticks_msec() + int(timeout_seconds * 1000)
		jobs.records[id]["artifact_dir"] = artifact_dir(id)
	return result

func stop_session(id: String, grace_seconds: float):
	var task := Deferred.new(grace_seconds + 3.0)
	if not sessions.has(id):
		task.resolve({"ok": false, "error": "Unknown or expired session: " + id})
		return task
	if not jobs.active(id):
		task.resolve({"ok": true, "value": {"session_id": id, "state": sessions[id].state, "already_stopped": true, "forced": false, "exit_code": sessions[id].exit_code}})
		return task
	if _stops.has(id):
		task.resolve({"ok": false, "error": "A stop request is already pending for " + id})
		return task
	# Cancel prior commands before enqueueing graceful quit. Their callbacks run
	# before the game's cleanup; no other session is affected.
	for rid in _pending.keys():
		if _pending.has(rid) and _pending[rid].session_id == id:
			_pending[rid].task.cancel("Session is stopping")
	var quit_sent := false
	if sessions[id].bridge_connected:
		quit_sent = _queue_quit(id, grace_seconds + 1.0)
	sessions[id].state = "stopping"
	sessions[id].termination_reason = "requested_stop"
	_stops[id] = {"task": task, "deadline": Time.get_ticks_msec() + int(grace_seconds * 1000), "forced": false, "kill_checked": false, "quit_sent": quit_sent}
	return task

func _poll_stops() -> void:
	for id in _stops.keys():
		var stop: Dictionary = _stops[id]
		if not jobs.active(id):
			stop.task.resolve({"ok": true, "value": {"session_id": id, "state": sessions[id].state, "already_stopped": false, "forced": stop.forced, "exit_code": sessions[id].exit_code}})
			_stops.erase(id)
		elif not stop.kill_checked and Time.get_ticks_msec() >= stop.deadline:
			stop.kill_checked = true
			if not jobs.terminate(id, "forced_stop"):
				stop.task.resolve({"ok": false, "error": "Could not terminate owned session " + id})
				_stops.erase(id)
			else:
				stop.forced = jobs.records[id].get("kill_sent", false)
		if _stops.has(id):
			if not stop.kill_checked and not stop.quit_sent and sessions[id].bridge_connected:
				stop.quit_sent = _queue_quit(id, maxf(1, (stop.deadline - Time.get_ticks_msec()) / 1000.0))
			stop.task.poll()
			# HTTP cancellation affects only delivery, not the owned stop action.
			# Keep the grace/kill state machine alive independently of the task.
			if stop.forced and Time.get_ticks_msec() >= stop.deadline + 3000:
				_stops.erase(id)

func _record_error(id: String, entry: Dictionary) -> void:
	var session: Dictionary = sessions[id]
	session._error_sequence += 1
	entry["source_sequence"] = entry.get("sequence")
	entry["sequence"] = session._error_sequence
	session._errors.append(entry)
	while session._errors.size() > 1000:
		session._errors.pop_front()

func errors(id: String, after: int, limit: int) -> Dictionary:
	if not sessions.has(id):
		return {"ok": false, "error": "Unknown or expired session: " + id}
	var session: Dictionary = sessions[id]
	var entries: Array = session.get("_errors", [])
	var out := []
	var cursor := after
	for entry in entries:
		if entry.sequence > after:
			out.append(entry.duplicate(true))
			cursor = entry.sequence
		if out.size() >= limit:
			break
	var truncated: bool = session.get("_source_gap", false) or (not entries.is_empty() and after < int(entries[0].sequence) - 1)
	return {"ok": true, "value": {"session_id": id, "state": session.state, "entries": out, "next_sequence": cursor, "truncated": truncated}}

func background_busy() -> bool:
	return build_jobs.active_id != "" or (background_id != "" and jobs.active(background_id))

func _queue_quit(id: String, timeout_seconds: float) -> bool:
	var task = request(id, "quit", {}, timeout_seconds)
	return not task.done or task.value.get("ok", false) == true

func _note_activity(item: Dictionary, bytes: int) -> void:
	var id: String = item.get("id", "")
	if bytes > 0 and id != "" and sessions.has(id):
		sessions[id]._heartbeat = Time.get_ticks_msec()
		if sessions[id].state in ["running", "stopping"]:
			sessions[id].bridge_connected = true
