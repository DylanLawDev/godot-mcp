extends "res://addons/godot_mcp/tests/test_case.gd"
const Tools = preload("res://addons/godot_mcp/tools/runtime_tools.gd")
class FakeManager:
	extends RefCounted
	var calls := []
	func launch(scene, headless, timeout_seconds):
		calls.append([scene, headless, timeout_seconds])
		return {"ok": true, "value": {"session_id": "fake", "scene": scene, "headless": headless, "state": "starting"}}

func test_run_project_passes_explicit_scene_and_options() -> void:
	var fake := FakeManager.new()
	var tools := Tools.new(fake)
	var result := tools.run_project({"scene": "examples/scenes/runner_demo.tscn", "headless": true, "startup_timeout_seconds": 20})
	assert_true(result.ok)
	assert_eq(result.value.state, "starting")
	assert_eq(fake.calls[0], ["res://examples/scenes/runner_demo.tscn", true, 20.0])

func test_run_project_uses_configured_main_and_uid() -> void:
	var old = ProjectSettings.get_setting("application/run/main_scene")
	var fake := FakeManager.new()
	var tools := Tools.new(fake)
	ProjectSettings.set_setting("application/run/main_scene", "res://examples/scenes/runner_demo.tscn")
	assert_true(tools.run_project({}).ok)
	var uid := ResourceUID.create_id()
	ResourceUID.add_id(uid, "res://examples/scenes/runner_demo.tscn")
	ProjectSettings.set_setting("application/run/main_scene", ResourceUID.id_to_text(uid))
	assert_true(tools.run_project({}).ok)
	ResourceUID.remove_id(uid)
	ProjectSettings.set_setting("application/run/main_scene", old)

func test_invalid_run_arguments_do_not_launch() -> void:
	var fake := FakeManager.new()
	var tools := Tools.new(fake)
	for args in [{"scene": ""}, {"scene": 3}, {"scene": "../outside.tscn"}, {"scene": "/tmp/outside.tscn"}, {"scene": "missing.tscn"}, {"scene": "examples/scripts/player.gd"}, {"headless": "true"}, {"startup_timeout_seconds": 0}, {"startup_timeout_seconds": 1.5}, {"startup_timeout_seconds": "5"}]:
		assert_false(tools.run_project(args).ok, str(args))
	assert_eq(fake.calls.size(), 0)
