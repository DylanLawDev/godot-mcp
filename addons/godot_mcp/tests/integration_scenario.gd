extends SceneTree
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const Tools = preload("res://addons/godot_mcp/tools/scenario_tools.gd")
var manager
var failures := []
func _initialize() -> void:
	manager = Sessions.new()
	_main.call_deferred()
func _main() -> void:
	var sources := ["examples/scenarios/move_right.json", "examples/scenarios/texture_readback.json"]
	if "--render" in OS.get_cmdline_user_args():
		sources.append("examples/scenarios/burst_capture.json")
	var tools := Tools.new(manager)
	for source in sources:
		var original := FileAccess.get_file_as_string(source)
		var result := tools.run_scenario({"scenario_path": source, "render": source.ends_with("burst_capture.json")})
		if not result.ok:
			failures.append(result)
			continue
		var id: String = result.value.scenario_id
		var duplicate := tools.run_scenario({"scenario_path": source})
		var running := tools.get_scenario_result({"scenario_id": id})
		if running.value.state != "running" or running.value.has("result"):
			failures.append("running result parsed prematurely")
		var deadline := Time.get_ticks_msec() + 15000
		while manager.jobs.active(id) and Time.get_ticks_msec() < deadline:
			manager.poll()
			await process_frame
		var completed := tools.get_scenario_result({"scenario_id": id})
		if not completed.ok or completed.value.state != "completed" or not completed.value.passed or duplicate.ok or completed.value.exit_code != 0:
			failures.append(completed)
		if tools.get_scenario_result({"scenario_id": id}) != completed:
			failures.append("completed result is not stable")
		if source != sources[0] and completed.value.artifacts.is_empty():
			failures.append("capture artifacts missing")
		for artifact in completed.value.artifacts:
			if not artifact.exists or not FileAccess.file_exists(artifact.file):
				failures.append("manifest references missing capture")
		if FileAccess.get_file_as_string(source) != original:
			failures.append("source scenario changed")
	manager.shutdown()
	print("SCENARIO INTEGRATION: ", failures)
	quit(0 if failures.is_empty() else 1)
