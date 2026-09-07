extends SceneTree
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
var manager
const Tools = preload("res://addons/godot_mcp/tools/runtime_tools.gd")
var failures := []

func _initialize() -> void:
	manager = Sessions.new()
	_main.call_deferred()

func _main() -> void:
	var tools := Tools.new(manager)
	var rendered := "--render" in OS.get_cmdline_user_args()
	var result: Dictionary = tools.run_project({"scene": "res://fixture.tscn", "headless": not rendered, "startup_timeout_seconds": 5})
	if not result.ok:
		failures.append(result)
		_finish()
		return
	var id: String = result.value.session_id
	if tools.run_project({"scene": "res://fixture.tscn", "headless": true}).ok:
		failures.append("duplicate launch accepted")
	var deadline := Time.get_ticks_msec() + 6000
	while tools.get_run_status({"session_id": id}).value.state == "starting" and Time.get_ticks_msec() < deadline:
		manager.poll()
		await process_frame
	var status: Dictionary = tools.get_run_status({"session_id": id}).value
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
		for format in ["file", "base64"]:
			var shot = tools.capture_game_frame({"session_id": id, "format": format, "downscale": 2})
			while not shot.done:
				manager.poll()
				await process_frame
			if rendered:
				if not shot.value.ok:
					failures.append(shot.value)
					continue
				var image := Image.new()
				if format == "file":
					image.load(shot.value.value.file)
				else:
					image.load_png_from_buffer(Marshalls.base64_to_raw(shot.value.value.base64))
				if image.is_empty() or image.get_pixel(10, 10).r < 0.9 or image.get_pixel(10, 10).g > 0.1:
					failures.append("capture did not contain fixture's rendered red pixels")
				if image.get_width() != int(shot.value.value.viewport_size[0]) / 2:
					failures.append("downscaled capture width mismatch")
			elif shot.value.ok or not shot.value.error.contains("Headless"):
				failures.append("headless capture must report unsupported rendering")
		var stop = tools.stop_project({"session_id": id})
		deadline = Time.get_ticks_msec() + 5000
		while manager.active_id != "" and Time.get_ticks_msec() < deadline:
			manager.poll()
			await process_frame
		if manager.active_id != "":
			failures.append("quit did not stop child")
		if not stop.done or not stop.value.ok or stop.value.value.forced:
			failures.append("graceful stop result was not successful")
		var repeated = tools.stop_project({"session_id": id})
		if not repeated.value.value.already_stopped:
			failures.append("repeat stop was not idempotent")
	status = tools.get_run_status({"session_id": id}).value
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
