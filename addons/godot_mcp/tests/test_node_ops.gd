extends "res://addons/godot_mcp/tests/test_case.gd"

const NodeOps = preload("res://addons/godot_mcp/utils/node_ops.gd")

func test_resolve_root_and_child() -> void:
	var root := Node.new()
	root.name = "Root"
	var child := Node.new()
	child.name = "Child"
	root.add_child(child)
	assert_eq(NodeOps.resolve(root, "."), root)
	assert_eq(NodeOps.resolve(root, "Child"), child)
	assert_eq(NodeOps.resolve(root, "Missing"), null)
	# Absolute paths and traversal outside the subtree are rejected.
	assert_eq(NodeOps.resolve(root, "/root/Child"), null)
	root.free()

func test_make_node() -> void:
	var n := NodeOps.make_node("Node2D", "Foo")
	assert_true(n is Node2D)
	assert_eq(str(n.name), "Foo")
	n.free()
	assert_eq(NodeOps.make_node("NotARealClass", "x"), null)
	# A non-Node class is rejected.
	assert_eq(NodeOps.make_node("RefCounted", "x"), null)

func test_value_applied_coercion() -> void:
	assert_true(NodeOps.value_applied(1, 1.0))   # int/float coercion
	assert_true(NodeOps.value_applied("a", "a"))
	assert_true(NodeOps.value_applied(StringName("a"), "a"))   # StringName/String coercion (e.g. `name`)
	assert_false(NodeOps.value_applied(StringName("a"), "b"))
	assert_false(NodeOps.value_applied("a", 1))   # mismatched types never crash

func test_apply_props_sets_and_reports() -> void:
	var n := Node2D.new()
	var res := NodeOps.apply_props(n, {"position": "Vector2(5, 6)"})
	assert_has(res["set"], "position")
	assert_eq(n.position, Vector2(5, 6))
	# Unknown property is reported, not applied.
	var res2 := NodeOps.apply_props(n, {"no_such_prop": "1"})
	assert_eq(res2["set"].size(), 0)
	assert_eq(res2["errors"].size(), 1)
	n.free()

func test_serialize_tree_shape() -> void:
	var root := Node.new()
	root.name = "Root"
	var child := Node2D.new()
	child.name = "Kid"
	root.add_child(child)
	var tree := NodeOps.serialize_tree(root, root)
	assert_eq(tree["name"], "Root")
	assert_eq(tree["path"], ".")
	assert_eq(tree["children"].size(), 1)
	assert_eq(tree["children"][0]["name"], "Kid")
	root.free()

func test_encode_props_returns_strings() -> void:
	var n := Node2D.new()
	n.name = "N"
	var props := NodeOps.encode_props(n)
	assert_true(props.has("position"))
	assert_eq(typeof(props["position"]), TYPE_STRING)
	n.free()

func test_bounded_tree_reports_depth_and_node_truncation() -> void:
	var scene := Node.new()
	scene.name = "Scene"
	for i in 5:
		var child := Node.new()
		child.name = "Child" + str(i)
		scene.add_child(child)
	var ops = preload("res://addons/godot_mcp/utils/node_ops.gd")
	var depth: Dictionary = ops.serialize_tree_bounded(scene, scene, 0, 100)
	assert_true(depth.truncated)
	assert_eq(depth.tree.children.size(), 0)
	var nodes: Dictionary = ops.serialize_tree_bounded(scene, scene, 8, 3)
	assert_true(nodes.truncated)
	assert_eq(nodes.tree.children.size(), 2)
	assert_eq(nodes.tree.children[0].path, "Child0")
	var full: Dictionary = ops.serialize_tree_bounded(scene, scene, 8, 100)
	assert_false(full.truncated)
	assert_eq(full.tree.children.size(), 5)
	scene.free()
