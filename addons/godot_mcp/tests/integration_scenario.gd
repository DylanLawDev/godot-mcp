extends SceneTree
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const Tools = preload("res://addons/godot_mcp/tools/scenario_tools.gd")
var manager
func _initialize() -> void:
	manager = Sessions.new()
	_main.call_deferred()
func _main() -> void:
	var tools := Tools.new(manager)
	var result := tools.run_scenario({"scenario_path": "examples/scenarios/move_right.json"})
	if not result.ok:
		print(result)
		manager.shutdown()
		quit(1)
		return
	var id: String = result.value.scenario_id
	var duplicate := tools.run_scenario({"scenario_path": "examples/scenarios/move_right.json"})
	var deadline := Time.get_ticks_msec() + 15000
	while manager.jobs.active(id) and Time.get_ticks_msec() < deadline:
		manager.poll()
		await process_frame
	var output: Variant = JSON.parse_string(FileAccess.get_file_as_string(result.value.result_path))
	var passed: bool = output is Dictionary and output.get("passed", false) and not duplicate.ok and manager.jobs.records[id].exit_code == 0
	print("SCENARIO INTEGRATION: ", passed, " ", result)
	manager.shutdown()
	quit(0 if passed else 1)
