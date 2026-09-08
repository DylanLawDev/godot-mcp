extends "res://addons/godot_mcp/tests/test_case.gd"
const Tools = preload("res://addons/godot_mcp/tools/scenario_tools.gd")
func test_missing_or_nonboolean_runner_ok_is_malformed() -> void:
	var directory := ProjectSettings.globalize_path("user://scenario_verdict_test")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("result.json")
	for invalid in [null, 1, "yes"]:
		var data := {"passed": true, "steps": [], "assertions": []}
		if invalid != null:
			data["ok"] = invalid
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(data))
		file.close()
		var result := Tools._read_completed_result({"id": "test", "result_path": path, "artifact_dir": directory, "exit_code": 0})
		assert_eq(result.state, "failed")
		assert_false(result.passed)
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(directory)
