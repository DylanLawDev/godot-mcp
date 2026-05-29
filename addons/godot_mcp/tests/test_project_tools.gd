extends "res://addons/godot_mcp/tests/test_case.gd"

const ProjectTools = preload("res://addons/godot_mcp/tools/project_tools.gd")

func test_get_project_info_has_name_and_godot_version() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_info({})
	assert_true(r["ok"])
	var info: Dictionary = r["value"]
	# project.godot sets application/config/name = "Godot MCP".
	assert_eq(info["name"], "Godot MCP")
	assert_ne(info["godot_version"], "")
	assert_true(info.has("autoloads"))
	assert_true(info.has("features"))
	assert_eq(info["autoloads"], [])
	assert_has(info["features"], "4.6")

func test_get_project_info_omits_empty_optionals() -> void:
	var pt = ProjectTools.new()
	var info: Dictionary = pt.get_project_info({})["value"]
	# project.godot defines no description/version → keys omitted.
	assert_false(info.has("description"))
	assert_false(info.has("version"))

func test_get_project_settings_all_author_set() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_settings({})
	assert_true(r["ok"])
	var settings: Dictionary = r["value"]
	assert_eq(settings["application/config/name"], "Godot MCP")
	# Engine defaults are NOT included (only project.godot entries).
	assert_false(settings.has("physics/common/physics_ticks_per_second"))

func test_get_project_settings_single_key() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_settings({"key": "application/config/name"})
	assert_true(r["ok"])
	assert_eq(r["value"]["value"], "Godot MCP")

func test_get_project_settings_missing_key_errors() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_settings({"key": "no/such/setting"})
	assert_false(r["ok"])
	assert_true(str(r["error"]).begins_with("Setting not found"))

func test_get_project_settings_prefix_filter() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_settings({"prefix": "application/"})
	assert_true(r["ok"])
	var settings: Dictionary = r["value"]
	assert_true(settings.has("application/config/name"))
	for k in settings:
		assert_true(str(k).begins_with("application/"))
