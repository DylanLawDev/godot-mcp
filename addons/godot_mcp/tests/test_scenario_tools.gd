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
