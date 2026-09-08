extends "res://addons/godot_mcp/tests/test_case.gd"
const Tools = preload("res://addons/godot_mcp/tools/scenario_tools.gd")

func test_capture_remapping_preserves_source_and_shared_directory() -> void:
	var source := {"scene": "res://examples/scenes/runner_demo.tscn", "steps": [{"type": "capture_frames", "dir": "/tmp/original", "count": 1}, {"type": "step_frames", "dir": "/tmp/original", "count": 2}, {"type": "capture_texture", "out": "/tmp/out.png"}]}
	var result := Tools.prepare_scenario(source, "/tmp/managed")
	assert_true(result.ok)
	assert_eq(source.steps[0].dir, "/tmp/original")
	assert_eq(result.value.steps[0].dir, result.value.steps[1].dir)
	assert_true(result.value.steps[2].out.begins_with("/tmp/managed/"))

func test_invalid_scenario_shapes_and_capture_paths() -> void:
	for scenario in [{}, {"scene": "../outside.tscn"}, {"scene": "missing.tscn"}, {"scene": "res://examples/scenes/main.tscn", "steps": [1]}, {"scene": "res://examples/scenes/main.tscn", "steps": [{"type": "capture_frames", "dir": 2}]}]:
		assert_false(Tools.prepare_scenario(scenario, "/tmp/managed").ok)

func test_completed_results_keep_assertion_failures_distinct() -> void:
	var directory := ProjectSettings.globalize_path("user://scenario_result_test")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("result.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"ok": true, "passed": false, "steps": [], "assertions": [{"passed": false}]}))
	file.close()
	var job := {"id": "test", "result_path": path, "artifact_dir": directory, "exit_code": 1, "output": []}
	var result := Tools._read_completed_result(job)
	assert_eq(result.state, "completed")
	assert_false(result.passed)
	job.exit_code = 0
	assert_eq(Tools._read_completed_result(job).state, "failed")
	job.termination_reason = "timeout"
	assert_eq(Tools._read_completed_result(job).state, "timed_out")
	job.erase("termination_reason")
	DirAccess.remove_absolute(path)
	assert_eq(Tools._read_completed_result(job).state, "failed")
	assert_false(Tools._contained("/tmp/elsewhere.png", directory))
	var escaped := Tools._artifact_manifest(directory, {"captures": [{"frames": [{"file": "/tmp/elsewhere.png"}]}]})
	assert_ne(escaped.error, "")
	DirAccess.remove_absolute(directory)
