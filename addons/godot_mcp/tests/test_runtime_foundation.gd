extends "res://addons/godot_mcp/tests/test_case.gd"
const Wire = preload("res://addons/godot_mcp/runtime/bridge_wire.gd")
const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const Registry = preload("res://addons/godot_mcp/tool_registry.gd")
const Handler = preload("res://addons/godot_mcp/mcp_handler.gd")
var pending
var cancelled := 0

func test_wire_fragmentation_and_coalescing() -> void:
	var wire := Wire.new()
	var bytes := Wire.encode({"hello": "π"})
	assert_eq(wire.feed(bytes.slice(0, 3)).size(), 0)
	var messages := wire.feed(bytes.slice(3) + bytes)
	assert_eq(messages.size(), 2)
	assert_eq(messages[0].hello, "π")
	assert_eq(wire.buffer.size(), 0)

func test_wire_rejects_invalid_lengths_and_payloads() -> void:
	var wire := Wire.new()
	wire.feed(PackedByteArray([255, 255, 255, 255]))
	assert_ne(wire.error, "")
	wire = Wire.new()
	wire.feed(PackedByteArray([0, 0, 0, 2, 91, 93]))
	assert_ne(wire.error, "")

func _deferred(_args: Dictionary):
	pending = Deferred.new()
	pending.on_cancel = func(): cancelled += 1
	return pending

func test_deferred_transforms_once_and_timeout_cancels() -> void:
	var d := Deferred.new()
	d.on_cancel = func(): cancelled += 1
	d.transform(func(v): return v.error)
	d.deadline_msec = 0
	d.poll()
	assert_true(d.done)
	assert_eq(d.value, "Request timed out")
	var count := cancelled
	d.cancel()
	d.resolve("wrong")
	assert_eq(cancelled, count)
	assert_eq(d.value, "Request timed out")

func test_handler_deferred_id_and_ping() -> void:
	var reg := Registry.new()
	reg.register("later", "later", {}, Callable(self, "_deferred"))
	var handler := Handler.new(reg)
	var out = handler.handle_message_async('{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"later"}}')
	assert_true(out is Deferred)
	assert_false(out.done)
	var ping = JSON.parse_string(handler.handle_message_async('{"jsonrpc":"2.0","id":"ping","method":"ping"}'))
	assert_eq(ping.id, "ping")
	pending.resolve({"ok": true, "value": {"answer": 42}})
	var result = JSON.parse_string(out.value)
	assert_eq(result.id, 7.0)
	assert_false(result.result.isError)
	assert_has(out.value, '"id":7,')

func test_sync_adapter_cancels_deferred_and_notifications_do_not_run() -> void:
	var reg := Registry.new()
	reg.register("later", "later", {}, Callable(self, "_deferred"))
	assert_true(reg.call_tool("later", {}).isError)
	var count := cancelled
	var handler := Handler.new(reg)
	assert_eq(handler.handle_message_async('{"method":"tools/call","params":{"name":"later"}}'), "")
	assert_eq(cancelled, count)

func test_session_request_without_connection_and_summary_redaction() -> void:
	var manager := Sessions.new()
	var out = manager.request("missing", "anything", {})
	assert_true(out.done)
	assert_false(out.value.ok)
	manager.sessions["a"] = {"session_id": "a", "_token": "secret", "_peer": null}
	assert_false(manager.summary("a").has("_token"))
	assert_eq(manager.summary("missing"), {})
	manager.shutdown()

class FakeJobs:
	extends RefCounted
	var records := {}
	var running := {}
	var fail_launch := false
	func launch(id, _executable, _args, kind):
		if fail_launch:
			return {"ok": false, "error": "injected spawn failure"}
		records[id] = {"pid": 123, "kind": kind, "state": "running", "started_at": "now", "output": []}
		running[id] = true
		return {"ok": true, "value": records[id]}
	func poll(): pass
	func active(id): return running.has(id)
	func terminate(id, reason = "stopped"):
		if records.has(id):
			running.erase(id)
			records[id].state = "failed"
			records[id].termination_reason = reason
		return true
	func shutdown(): running.clear()

class FakePeer:
	extends RefCounted
	var disconnected := false
	func put_data(_bytes): return OK
	func disconnect_from_host(): disconnected = true

func test_spawn_failure_and_startup_timeout() -> void:
	var jobs := FakeJobs.new()
	var manager := Sessions.new(jobs)
	jobs.fail_launch = true
	assert_false(manager.launch("res://examples/scenes/main.tscn", true).ok)
	assert_eq(manager.active_id, "")
	jobs.fail_launch = false
	var started := manager.launch("res://examples/scenes/main.tscn", true)
	assert_true(started.ok)
	var id: String = started.value.session_id
	assert_false(manager.launch("res://examples/scenes/main.tscn", true).ok)
	manager.sessions[id]._deadline = 0
	manager.poll()
	assert_eq(manager.summary(id).state, "failed")
	assert_eq(manager.summary(id).termination_reason, "startup_timeout")
	assert_eq(manager.active_id, "")
	manager.shutdown()

func test_handshake_authentication_stale_session_and_disconnect() -> void:
	var manager := Sessions.new(FakeJobs.new())
	manager.active_id = "a"
	manager.sessions.a = {"session_id": "a", "state": "starting", "bridge_connected": false, "_token": "right", "_peer": null}
	var peer := FakePeer.new()
	var item := {"peer": peer, "id": ""}
	manager._receive(item, {"kind": "hello", "session_id": "a", "version": 1, "token": "wrong"})
	assert_true(peer.disconnected)
	peer = FakePeer.new()
	item = {"peer": peer, "id": ""}
	manager._receive(item, {"kind": "hello", "session_id": "old", "version": 1, "token": "right"})
	assert_true(peer.disconnected)
	peer = FakePeer.new()
	item = {"peer": peer, "id": ""}
	manager._receive(item, {"kind": "hello", "session_id": "a", "version": 1, "token": "right"})
	assert_eq(item.id, "a")
	manager._receive(item, {"kind": "ready", "session_id": "a", "capabilities": {}})
	var pending_command = manager.request("a", "test", {})
	manager._drop(item)
	assert_true(pending_command.done)
	assert_false(pending_command.value.ok)
	assert_false(manager.sessions.a.bridge_connected)
	manager.shutdown()

func test_stop_owned_session_forced_and_idempotent() -> void:
	var jobs := FakeJobs.new()
	var manager := Sessions.new(jobs)
	var result := manager.launch("res://examples/scenes/main.tscn", true)
	var id: String = result.value.session_id
	var stop = manager.stop_session(id, 0)
	assert_false(stop.done)
	assert_eq(manager.summary(id).state, "stopping")
	manager.poll()
	manager.poll()
	assert_true(stop.done)
	assert_true(stop.value.ok)
	assert_true(stop.value.value.forced)
	assert_true(manager.stop_session(id, 0).value.value.already_stopped)
	assert_false(manager.stop_session("unknown", 0).value.ok)
	var newer := manager.launch("res://examples/scenes/main.tscn", true)
	manager.stop_session(id, 0)
	assert_true(jobs.active(newer.value.session_id))
	manager.shutdown()

func test_max_frame_followed_by_coalesced_heartbeat() -> void:
	var frame := Wire.encode({"data": "x".repeat(Wire.MAX_BYTES - 11)})
	assert_eq(frame.size(), Wire.MAX_BYTES + 4)
	var wire := Wire.new()
	assert_eq(wire.feed(frame.slice(0, frame.size() - 20)).size(), 0)
	var messages := wire.feed(frame.slice(frame.size() - 20) + Wire.encode({"kind": "heartbeat"}))
	assert_eq(wire.error, "")
	assert_eq(messages.size(), 2)
	assert_eq(messages[1].kind, "heartbeat")

func test_utf8_multibyte_boundary_is_lossless() -> void:
	var jobs = preload("res://addons/godot_mcp/runtime/process_jobs.gd")
	var original := "hello π 😀 世界"
	var bytes := original.to_utf8_buffer()
	for split in range(1, bytes.size()):
		var first: Dictionary = jobs.decode_utf8(bytes.slice(0, split))
		var second: Dictionary = jobs.decode_utf8(first.tail + bytes.slice(split))
		assert_eq(first.text + second.text, original)
		assert_true(second.tail.is_empty())

func test_exited_process_drains_more_than_one_poll_of_output() -> void:
	var jobs = preload("res://addons/godot_mcp/runtime/process_jobs.gd").new()
	var path := "user://runtime_pipe_fixture.txt"
	var content := "x".repeat(100000) + "FINAL_DIAGNOSTIC_世界"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	jobs.records["test"] = {"sequence": 0, "output": [], "state": "running"}
	# Inject the exited-process state; the regular file supplies more buffered
	# bytes than a single per-frame draining budget.
	jobs.process_is_running = func(_pid): return false
	jobs.process_exit_code = func(_pid): return 0
	jobs._handles["test"] = {"pid": 2147483647, "stdio": FileAccess.open(path, FileAccess.READ), "stderr": null}
	jobs.poll()
	assert_true(jobs.active("test"), "must not discard the unread tail on exit")
	for _i in 10:
		jobs.poll()
	assert_false(jobs.active("test"))
	var actual := ""
	for entry in jobs.records.test.output:
		actual += entry.text
	assert_eq(actual, content)
	DirAccess.remove_absolute(path)
	jobs.shutdown()

func test_cancelled_stop_response_keeps_forced_cleanup() -> void:
	var jobs := FakeJobs.new()
	var manager := Sessions.new(jobs)
	var result := manager.launch("res://examples/scenes/main.tscn", true)
	var id: String = result.value.session_id
	var stop = manager.stop_session(id, 10)
	stop.cancel("HTTP client disconnected")
	manager.poll()
	assert_true(manager._stops.has(id))
	assert_true(jobs.active(id))
	manager._stops[id].deadline = Time.get_ticks_msec()
	manager.poll()
	manager.poll()
	assert_false(jobs.active(id))
	assert_eq(manager.active_id, "")
	manager.shutdown()
