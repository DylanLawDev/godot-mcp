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

func test_status_idle_default_explicit_and_retained() -> void:
	var sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd").new()
	var tools := Tools.new(sessions)
	assert_eq(tools.get_run_status({}).value.state, "idle")
	sessions.sessions.old = {"state": "exited", "session_id": "old", "exit_code": null}
	sessions.latest_id = "old"
	assert_eq(tools.get_run_status({}).value.session_id, "old")
	sessions.sessions.new = {"state": "running", "session_id": "new", "bridge_connected": false}
	sessions.active_id = "new"
	assert_eq(tools.get_run_status({}).value.session_id, "new")
	var old: Dictionary = tools.get_run_status({"session_id": "old"}).value
	assert_eq(old.state, "exited")
	assert_eq(old.active_session_id, "new")
	assert_eq(old.exit_code, null)
	assert_eq(tools.get_run_status({}).value.state, "running")
	for args in [{"session_id": "unknown"}, {"session_id": ""}, {"session_id": 42}]:
		assert_false(tools.get_run_status(args).ok)
	sessions.shutdown()

func test_stop_validates_explicit_session_and_grace() -> void:
	var tools := Tools.new(FakeManager.new())
	for args in [{}, {"session_id": ""}, {"session_id": 4}, {"session_id": "a", "grace_seconds": "2"}, {"session_id": "a", "grace_seconds": -1}, {"session_id": "a", "grace_seconds": 11}]:
		assert_false(tools.stop_project(args).ok)

func test_capture_validates_frame_options() -> void:
	var tools := Tools.new(FakeManager.new())
	for args in [{}, {"session_id": 2}, {"session_id": "a", "downscale": 0}, {"session_id": "a", "downscale": 1.2}, {"session_id": "a", "downscale": 17}, {"session_id": "a", "format": "jpeg"}]:
		assert_false(tools.capture_game_frame(args).ok)
	var commands = preload("res://addons/godot_mcp/runtime/runtime_commands.gd").new(null)
	assert_false(commands.capture_game_frame({}).value.ok)

func test_resize_requires_bounded_integer_dimensions() -> void:
	var tools := Tools.new(FakeManager.new())
	for args in [{}, {"session_id": "a"}, {"session_id": "a", "width": 0, "height": 100}, {"session_id": "a", "width": 640.5, "height": 480}, {"session_id": "a", "width": 640, "height": "480"}, {"session_id": "a", "width": 640, "height": 9000}]:
		assert_false(tools.resize_game_window(args).ok)

func test_runtime_tree_limits_and_path_types() -> void:
	var tools := Tools.new(FakeManager.new())
	for args in [{}, {"session_id": "a", "path": 2}, {"session_id": "a", "max_depth": -1}, {"session_id": "a", "max_nodes": 0}, {"session_id": "a", "max_nodes": 10001}]:
		assert_false(tools.get_runtime_tree(args).ok)
