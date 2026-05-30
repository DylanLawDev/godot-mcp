extends "res://addons/godot_mcp/tests/test_case.gd"

const ScenarioEngine = preload("res://addons/godot_mcp/runtime/scenario_engine.gd")

# Build a small Node2D root with a named child for path-based steps.
func _make_root() -> Node:
	var root := Node2D.new()
	root.name = "Root"
	var child := Node2D.new()
	child.name = "Sub"
	root.add_child(child)
	return root

func test_set_property_step() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var res := eng.execute({"type": "set_property", "path": "Sub", "properties": {"position": "Vector2(10, 0)"}})
	assert_true(res["ok"])
	assert_eq(root.get_node("Sub").position, Vector2(10, 0))
	root.free()

func test_set_property_unknown_node_is_fatal() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var res := eng.execute({"type": "set_property", "path": "Nope", "properties": {}})
	assert_false(res["ok"])
	assert_true(res.get("fatal", false))
	root.free()

func test_create_and_delete_node() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var c := eng.execute({"type": "create_node", "parent_path": ".", "node_type": "Node", "name": "Made"})
	assert_true(c["ok"])
	assert_ne(root.get_node_or_null("Made"), null)
	var d := eng.execute({"type": "delete_node", "path": "Made"})
	assert_true(d["ok"])
	root.free()

func test_delete_root_rejected() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_false(eng.execute({"type": "delete_node", "path": "."})["ok"])
	root.free()

func test_call_method_captures_return() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var res := eng.execute({"type": "call_method", "path": "Sub", "method": "get_class"})
	assert_true(res["ok"])
	assert_has(res["detail"], "Node2D")
	root.free()

func test_call_method_missing_is_fatal() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_false(eng.execute({"type": "call_method", "path": "Sub", "method": "no_such_method"})["ok"])
	root.free()

func test_wait_steps_return_frame_counts() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_eq(eng.execute({"type": "wait_frames", "count": 5})["frames"], 5)
	var fps := int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60))
	assert_eq(eng.execute({"type": "wait_seconds", "seconds": 1.0})["frames"], fps)
	root.free()

func test_unknown_step_type() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_false(eng.execute({"type": "bogus"})["ok"])
	root.free()

func test_watch_signal_idempotent() -> void:
	var root := _make_root()
	root.add_user_signal("pinged")
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_true(eng.execute({"type": "watch_signal", "path": ".", "signal": "pinged"})["ok"])
	# Re-watching the same signal must not add a second connection.
	assert_true(eng.execute({"type": "watch_signal", "path": ".", "signal": "pinged"})["ok"])
	assert_eq(root.get_signal_connection_list("pinged").size(), 1)
	root.free()
