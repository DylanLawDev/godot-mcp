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

# Build a detached tree:  Root -> [Child (Node2D), Branch -> Leaf]
func _make_tree() -> Node:
	var root := Node.new()
	root.name = "Root"
	var child := Node2D.new()
	child.name = "Child"
	root.add_child(child)
	var branch := Node.new()
	branch.name = "Branch"
	root.add_child(branch)
	var leaf := Node.new()
	leaf.name = "Leaf"
	branch.add_child(leaf)
	return root

func test_serialize_tree_shape_and_paths() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var tree: Dictionary = st._serialize_tree(root, root)
	assert_eq(tree["name"], "Root")
	assert_eq(tree["type"], "Node")
	assert_eq(tree["path"], ".")
	assert_eq(tree["children"].size(), 2)
	var child: Dictionary = tree["children"][0]
	assert_eq(child["name"], "Child")
	assert_eq(child["type"], "Node2D")
	assert_eq(child["path"], "Child")
	assert_eq(child["script"], null)
	var branch: Dictionary = tree["children"][1]
	assert_eq(branch["children"][0]["path"], "Branch/Leaf")
	root.free()
