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
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(source.path_join("project.godot"), 0x1ed)
	DirAccess.make_dir_recursive_absolute(source.path_join("assets/build"))
	var nested := FileAccess.open(source.path_join("assets/build/resource.txt"), FileAccess.WRITE)
	nested.store_string("referenced nested resource")
	nested.close()
	var hash := FileAccess.get_sha256(source.path_join("project.godot"))
	var copy := Snapshot.new(source, target)
	while not copy.done:
		copy.poll()
	assert_eq(copy.error, "")
	if OS.get_name() != "Windows":
		assert_eq(FileAccess.get_unix_permissions(target.path_join("project.godot")), 0x1ed)
	assert_true(FileAccess.file_exists(target.path_join("assets/build/resource.txt")))
	assert_false(DirAccess.dir_exists_absolute(target.path_join(".godot")))
	assert_false(DirAccess.dir_exists_absolute(target.path_join(".git")))
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(target.path_join("project.godot"), 0x124)
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

func test_logs_are_json_safe_without_raw_ansi() -> void:
	assert_eq(Pipeline.clean_log(String.chr(27) + "[90mtext" + String.chr(27) + "[0m\n"), "text\n")

func test_validation_logger_counts_stderr_but_not_warnings() -> void:
	var logger = preload("res://addons/godot_mcp/runtime/validation_bootstrap.gd").ValidationLogger.new()
	logger._log_message("ordinary", false)
	logger._log_error("fixture", "fixture.gd", 1, "warning", "", false, Logger.ERROR_TYPE_WARNING, [])
	assert_eq(logger.failures, 0)
	logger._log_message("stderr failure", true)
	assert_eq(logger.failures, 1)

func test_nested_report_text_is_sanitized() -> void:
	var sanitizer = preload("res://addons/godot_mcp/runtime/log_sanitizer.gd")
	var result: Dictionary = sanitizer.clean_value({"diagnostics": [{"text": String.chr(27) + "[31mred", "backtraces": [{"file": "file" + String.chr(7)}]}]})
	assert_eq(result.diagnostics[0].text, "red")
	assert_eq(result.diagnostics[0].backtraces[0].file, "file")

func test_logger_freeze_has_consistent_count_and_entries() -> void:
	var logger = preload("res://addons/godot_mcp/runtime/validation_bootstrap.gd").ValidationLogger.new()
	logger._log_message("first", true)
	var worker := Thread.new()
	worker.start(func():
		for _i in 500:
			logger._log_message("thread error", true)
	)
	var frozen: Dictionary = logger.freeze()
	worker.wait_to_finish()
	logger._log_message("late", true)
	assert_eq(frozen.error_count, frozen.diagnostics.size())
	assert_eq(logger.freeze(), frozen)
