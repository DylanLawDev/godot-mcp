extends "res://addons/godot_mcp/tests/test_case.gd"

const SceneTools = preload("res://addons/godot_mcp/tools/scene_tools.gd")

# Headless: no edited scene exists, so every public tool reports it.
func test_get_scene_tree_no_scene_open() -> void:
	var st = SceneTools.new()
	var r: Dictionary = st.get_scene_tree({})
	assert_false(r["ok"])
	assert_eq(r["error"], "No scene is currently open")

func test_get_node_properties_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.get_node_properties({"path": "."})["ok"])

func test_create_node_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.create_node({"parent_path": ".", "type": "Node"})["ok"])

func test_delete_node_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.delete_node({"path": "Foo"})["ok"])

func test_modify_node_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.modify_node({"path": ".", "properties": {}})["ok"])
