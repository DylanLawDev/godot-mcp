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

func test_resolve_root_and_nested_and_missing() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	assert_eq(st._resolve(root, "."), root)
	assert_eq(st._resolve(root, "Branch/Leaf").name, "Leaf")
	assert_eq(st._resolve(root, "Nope/Missing"), null)
	root.free()

func test_encode_props_includes_value_and_skips_separators() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	n.position = Vector2(3, 4)
	var props: Dictionary = st._encode_props(n)
	# position round-trips through var_to_str
	assert_true(props.has("position"))
	assert_eq(props["position"], var_to_str(Vector2(3, 4)))
	# Category/group separator rows (e.g. "Node2D", "Transform") are not real props.
	assert_false(props.has("Node2D"))
	n.free()

func test_attach_sets_parent_and_owner() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var n := Node.new()
	n.name = "New"
	st._attach(root, n, root)
	assert_eq(n.get_parent(), root)
	assert_eq(n.owner, root)
	root.free()

func test_detach_removes_child() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var leaf := st._resolve(root, "Branch/Leaf")
	var parent := leaf.get_parent()
	st._detach(parent, leaf)
	assert_eq(leaf.get_parent(), null)
	assert_eq(parent.get_child_count(), 0)
	leaf.free()  # _detach does not free; we own it now
	root.free()

func test_apply_props_sets_known_reports_unknown() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	var res: Dictionary = st._apply_props(n, {"position": var_to_str(Vector2(5, 6)), "bogus_xyz": "1"})
	assert_eq(n.position, Vector2(5, 6))
	assert_has(res["set"], "position")
	assert_eq(res["errors"].size(), 1)
	assert_eq(res["errors"][0]["name"], "bogus_xyz")
	n.free()

func test_make_node_validates_type() -> void:
	var st = SceneTools.new()
	# Valid instantiable Node subclass:
	var ok_node := st._make_node("Node2D", "Thing")
	assert_ne(ok_node, null)
	assert_eq(ok_node.name, "Thing")
	ok_node.free()
	# Not a Node (Resource) and a bogus class both reject:
	assert_eq(st._make_node("Resource", ""), null)
	assert_eq(st._make_node("NotARealClass", ""), null)

func test_decode_props_separates_valid_and_unknown() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	var d: Dictionary = st._decode_props(n, {"position": var_to_str(Vector2(1, 2)), "bogus": "1"})
	assert_eq(d["valid"].size(), 1)
	assert_eq(d["valid"][0]["name"], "position")
	assert_eq(d["valid"][0]["value"], Vector2(1, 2))
	assert_eq(d["errors"].size(), 1)
	assert_eq(d["errors"][0]["name"], "bogus")
	n.free()

func test_apply_props_reports_type_mismatch_as_error() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	# A String value cannot apply to a Vector2 property: Godot drops it silently.
	var res: Dictionary = st._apply_props(n, {"position": var_to_str("hello")})
	assert_eq(res["set"].size(), 0)
	assert_eq(res["errors"].size(), 1)
	assert_eq(res["errors"][0]["name"], "position")
	n.free()

func test_apply_props_allows_int_to_float_coercion() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	var res: Dictionary = st._apply_props(n, {"rotation": var_to_str(2)})  # rotation is float
	assert_has(res["set"], "rotation")
	assert_eq(res["errors"].size(), 0)
	n.free()
