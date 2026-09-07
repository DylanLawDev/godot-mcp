extends SceneTree
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
var manager
var failures := []

func _initialize() -> void:
	manager = Sessions.new()
	_main.call_deferred()

func _main() -> void:
	var result: Dictionary = manager.launch("res://fixture.tscn", true, 5)
	if not result.ok:
		failures.append(result)
		_finish()
		return
	var id: String = result.value.session_id
	if manager.launch("res://fixture.tscn", true).ok:
		failures.append("duplicate launch accepted")
	var deadline := Time.get_ticks_msec() + 6000
	while manager.summary(id).state == "starting" and Time.get_ticks_msec() < deadline:
		manager.poll()
		await process_frame
	var status: Dictionary = manager.summary(id)
	print("READY: ", JSON.stringify(status))
	if status.state != "running":
		failures.append("did not become ready")
	else:
		var unknown = manager.request(id, "not_a_command", {})
		while not unknown.done:
			manager.poll()
			await process_frame
		if unknown.value.ok:
			failures.append("unknown command succeeded")
		var stop = manager.request(id, "quit", {})
		deadline = Time.get_ticks_msec() + 5000
		while manager.active_id != "" and Time.get_ticks_msec() < deadline:
			manager.poll()
			await process_frame
		if manager.active_id != "":
			failures.append("quit did not stop child")
		if not stop.done or not stop.value.ok:
			failures.append("quit reply was lost before disconnect")
	status = manager.summary(id)
	print("EXIT: ", JSON.stringify(status))
	var output := JSON.stringify(status.diagnostics)
	if not output.contains("AUTOLOAD_OK"):
		failures.append("autoload unavailable in bootstrap")
	if not output.contains("PAUSED_READY"):
		failures.append("paused fixture unavailable")
	_finish()

func _finish() -> void:
	manager.shutdown()
	print("RUNTIME INTEGRATION: ", failures)
	quit(0 if failures.is_empty() else 1)
