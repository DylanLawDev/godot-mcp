extends "res://addons/godot_mcp/tests/test_case.gd"
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const Tools = preload("res://addons/godot_mcp/tools/build_tools.gd")
const Pipeline = preload("res://addons/godot_mcp/runtime/build_pipeline.gd")
const Snapshot = preload("res://addons/godot_mcp/runtime/project_snapshot.gd")
const Jobs = preload("res://addons/godot_mcp/runtime/process_jobs.gd")
func test_validation_arguments_and_job_kind() -> void:
	var manager := Sessions.new()
	var tools := Tools.new(manager)
	for args in [{"startup_seconds": false}, {"timeout_seconds": 1801}, {"scene": 3}, {"scene": "../outside.tscn"}, {"job_id": "unknown"}, {"job_id": "id", "scene": "res://x"}]:
		assert_false(tools.validate_project(args).ok)
	manager.build_jobs.records["export"] = {"kind": "export"}
	assert_false(tools.validate_project({"job_id": "export"}).ok)
	manager.build_jobs.active_id = "busy"
	assert_false(tools.validate_project({}).ok)
	manager.build_jobs.active_id = ""
	manager.shutdown()
func test_errors_survive_output_eviction_and_chunk_boundaries() -> void:
	var jobs := Jobs.new()
	jobs.records["id"] = {"sequence": 0, "output": []}
	jobs._append_output("id", "stderr", "SCRIPT ER")
	jobs._append_output("id", "stderr", "ROR: broken\n")
	for _i in 1001:
		jobs._append_output("id", "stdout", "ordinary log\n")
	assert_true(jobs.records.id.engine_errors)
	assert_false(Pipeline.output_has_errors([{"text": "WARNING: only a warning\n"}]))
	assert_true(Pipeline.output_has_errors([{"text": "SCRIPT ER"}, {"text": "ROR: broken"}]))
func test_snapshot_preserves_settings_and_excludes_cache() -> void:
	var source := Sessions.artifact_dir(Sessions.new_id())
	var target := source + " copy"
	DirAccess.make_dir_recursive_absolute(source.path_join(".godot"))
	DirAccess.make_dir_recursive_absolute(source.path_join(".git"))
	var config := ConfigFile.new()
	config.set_value("application", "run/main_scene", "res://main.tscn")
	config.set_value("autoload", "Fixture", "*res://fixture.gd")
	config.set_value("editor_plugins", "enabled", PackedStringArray(["res://addons/godot_mcp/plugin.cfg", "res://addons/other/plugin.cfg"]))
	config.save(source.path_join("project.godot"))
	var marker := FileAccess.open(source.path_join(".godot/marker"), FileAccess.WRITE)
	marker.store_string("unchanged")
	marker.close()
	var hash := FileAccess.get_sha256(source.path_join("project.godot"))
	var copy := Snapshot.new(source, target)
	while not copy.done:
		copy.poll()
	assert_eq(copy.error, "")
	assert_false(DirAccess.dir_exists_absolute(target.path_join(".godot")))
	assert_false(DirAccess.dir_exists_absolute(target.path_join(".git")))
	assert_eq(Snapshot.disable_mcp(target.path_join("project.godot")), OK)
	config.load(target.path_join("project.godot"))
	assert_eq(config.get_value("autoload", "Fixture"), "*res://fixture.gd")
	assert_eq(config.get_value("editor_plugins", "enabled"), PackedStringArray(["res://addons/other/plugin.cfg"]))
	assert_eq(FileAccess.get_sha256(source.path_join("project.godot")), hash)
	for path in [source, target]:
		var cleanup := Snapshot.new(path, "", true)
		while not cleanup.done:
			cleanup.poll()
		assert_eq(cleanup.error, "")
		assert_false(DirAccess.dir_exists_absolute(path))
