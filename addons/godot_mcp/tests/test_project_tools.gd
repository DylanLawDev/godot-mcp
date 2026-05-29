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
