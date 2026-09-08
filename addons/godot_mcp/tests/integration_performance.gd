extends SceneTree
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const Tools = preload("res://addons/godot_mcp/tools/runtime_tools.gd")
var manager
var failures := []
func _initialize() -> void:
	manager = Sessions.new()
	_main.call_deferred()
func _main() -> void:
	var tools := Tools.new(manager)
	var launched := tools.run_project({"scene": "res://examples/scenes/performance_demo.tscn", "headless": "--render" not in OS.get_cmdline_user_args()})
	if not launched.ok:
		failures.append(launched)
		_finish()
		return
	var id: String = launched.value.session_id
	while manager.summary(id).state == "starting":
		manager.poll()
		await process_frame
	var task = tools.sample_performance({"session_id": id, "duration_seconds": 3, "interval_ms": 16, "custom_monitors": ["demo/jobs_ms", "missing"]})
	while not task.done:
		manager.poll()
		await process_frame
	if not task.value.ok:
		failures.append(task.value)
	else:
		var value: Dictionary = task.value.value
		if value.samples.size() < 2 or value.summary["custom/demo/jobs_ms"].mean != 1.25 or "missing" not in value.unavailable_monitors or value.summary.node_count.min < 1 or value.summary.frame_time_ms.min <= 0:
			failures.append(value)
		for i in range(1, value.samples.size()):
			if value.samples[i].elapsed_ms <= value.samples[i - 1].elapsed_ms:
				failures.append("sample timestamps did not advance")
	var long_task = tools.sample_performance({"session_id": id, "duration_seconds": 30, "interval_ms": 16})
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 150:
		manager.poll()
		await process_frame
	var tree = tools.get_runtime_tree({"session_id": id})
	while not tree.done:
		manager.poll()
		await process_frame
	if not tree.value.ok:
		failures.append("runtime blocked by sampling")
	var stop = tools.stop_project({"session_id": id, "grace_seconds": 10})
	while not stop.done:
		manager.poll()
		await process_frame
	var partial: Variant = JSON.parse_string(long_task.value.get("error", ""))
	if not partial is Dictionary or not partial.get("partial", false) or partial.get("samples", []).is_empty():
		failures.append("stop lost partial performance samples")
	_finish()
func _finish() -> void:
	manager.shutdown()
	print("PERFORMANCE INTEGRATION: ", failures)
	quit(0 if failures.is_empty() else 1)
