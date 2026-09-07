extends "res://addons/godot_mcp/tests/test_case.gd"
const Export = preload("res://addons/godot_mcp/runtime/export_support.gd")
const Snapshot = preload("res://addons/godot_mcp/runtime/project_snapshot.gd")
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const Tools = preload("res://addons/godot_mcp/tools/build_tools.gd")
func test_exact_argument_array() -> void:
	for mode in ["debug", "release"]:
		assert_eq(Export.arguments("/tmp/project with spaces", "Linux $(touch nope)", mode, "/tmp/output with spaces/game"), PackedStringArray(["--headless", "--path", "/tmp/project with spaces", "--export-" + mode, "Linux $(touch nope)", "/tmp/output with spaces/game"]))
func test_presets_and_artifacts() -> void:
	var path := Sessions.artifact_dir(Sessions.new_id())
	DirAccess.make_dir_recursive_absolute(path)
	assert_false(Export.prepare("Linux", "debug", path).ok)
	var config := ConfigFile.new()
	config.set_value("preset.0", "name", "Linux")
	config.set_value("preset.0", "platform", "Web")
	config.save(path.path_join("export_presets.cfg"))
	assert_false(Export.prepare("Linux", "debug", path).ok)
	assert_false(Export.prepare("unknown", "debug", path).ok)
	config.set_value("preset.0", "platform", "Linux")
	config.set_value("preset.0.options", "custom_template/debug", path.path_join("missing-template"))
	config.save(path.path_join("export_presets.cfg"))
	assert_false(Export.prepare("Linux", "debug", path).ok)
	var file := FileAccess.open(path.path_join("template"), FileAccess.WRITE)
	file.store_string("fixture")
	file.close()
	config.set_value("preset.0.options", "custom_template/debug", path.path_join("template"))
	config.save(path.path_join("export_presets.cfg"))
	assert_true(Export.prepare("Linux", "debug", path).ok)
	assert_false(Export.manifest(path, path.path_join("missing-output")).ok)
	file = FileAccess.open(path.path_join("empty"), FileAccess.WRITE)
	file.close()
	assert_false(Export.manifest(path, path.path_join("empty")).ok)
	var manifest := Export.manifest(path, path.path_join("template"))
	assert_true(manifest.ok)
	assert_eq(manifest.value.size(), 3)
	var cleanup := Snapshot.new(path, "", true)
	while not cleanup.done:
		cleanup.poll()
func test_tool_limits() -> void:
	var manager := Sessions.new()
	var tools := Tools.new(manager)
	for args in [{}, {"preset": false}, {"preset": "Linux", "mode": "test"}, {"preset": "Linux", "timeout_seconds": 3601}, {"job_id": "unknown"}, {"job_id": "id", "mode": "debug"}]:
		assert_false(tools.export_build(args).ok)
	manager.shutdown()

func test_build_logs_do_not_emit_raw_ansi_controls() -> void:
	var pipeline = preload("res://addons/godot_mcp/runtime/build_pipeline.gd")
	assert_eq(pipeline.clean_log(String.chr(27) + "[90mtext" + String.chr(27) + "[0m\n"), "text\n")
