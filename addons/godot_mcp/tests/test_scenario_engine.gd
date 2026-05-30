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

func test_set_property_unknown_property_is_fatal() -> void:
	# A property that can't be applied must fail the step, not pass silently.
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var res := eng.execute({"type": "set_property", "path": "Sub", "properties": {"no_such_prop": "1"}})
	assert_false(res["ok"])
	assert_true(res.get("fatal", false))
	root.free()

func test_create_node_with_bad_property_is_fatal() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var res := eng.execute({"type": "create_node", "parent_path": ".", "node_type": "Node2D", "name": "Made", "properties": {"no_such_prop": "1"}})
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

func test_assert_property_ops() -> void:
	var root := _make_root()
	root.get_node("Sub").position = Vector2(100, 0)
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var gt := eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "gt", "value": "50"})
	assert_true(gt["passed"])
	var eq := eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "eq", "value": "100"})
	assert_true(eq["passed"])
	var lt := eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "lt", "value": "50"})
	assert_false(lt["passed"])
	root.free()

func test_assert_property_plain_string() -> void:
	# A plain-string expected value (not a quoted variant literal) must compare as
	# a string, so string-valued properties like `name` can be asserted directly.
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_true(eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "name", "op": "eq", "value": "Sub"})["passed"])
	assert_false(eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "name", "op": "eq", "value": "Other"})["passed"])
	root.free()

func test_assert_node_exists_and_absent() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_true(eng.execute({"type": "assert", "kind": "node_exists", "path": "Sub"})["passed"])
	assert_true(eng.execute({"type": "assert", "kind": "node_absent", "path": "Ghost"})["passed"])
	assert_false(eng.execute({"type": "assert", "kind": "node_exists", "path": "Ghost"})["passed"])
	root.free()

func test_assert_in_group() -> void:
	var root := _make_root()
	root.get_node("Sub").add_to_group("enemies")
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_true(eng.execute({"type": "assert", "kind": "in_group", "path": "Sub", "group": "enemies"})["passed"])
	assert_false(eng.execute({"type": "assert", "kind": "in_group", "path": "Sub", "group": "allies"})["passed"])
	root.free()

func test_watch_and_assert_signal_count() -> void:
	var root := _make_root()
	root.add_user_signal("died")
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_true(eng.execute({"type": "watch_signal", "path": ".", "signal": "died"})["ok"])
	root.emit_signal("died")
	root.emit_signal("died")
	var a := eng.execute({"type": "assert", "kind": "signal_count", "path": ".", "signal": "died", "op": "eq", "value": "2"})
	assert_true(a["passed"])
	assert_eq(a["actual"], 2)
	root.free()

func test_watch_and_assert_signal_count_with_args() -> void:
	# Covers the unbind(argc) path: a signal carrying args must still count.
	var root := _make_root()
	root.add_user_signal("hit", [{"name": "amount", "type": TYPE_INT}])
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_true(eng.execute({"type": "watch_signal", "path": ".", "signal": "hit"})["ok"])
	root.emit_signal("hit", 7)
	root.emit_signal("hit", 3)
	root.emit_signal("hit", 1)
	var a := eng.execute({"type": "assert", "kind": "signal_count", "path": ".", "signal": "hit", "op": "ge", "value": "3"})
	assert_true(a["passed"])
	assert_eq(a["actual"], 3)
	root.free()

func test_signal_count_without_watch_fails() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_false(eng.execute({"type": "assert", "kind": "signal_count", "path": ".", "signal": "x", "op": "eq", "value": "0"})["passed"])
	root.free()

func test_results_verdict() -> void:
	var root := _make_root()
	root.get_node("Sub").position = Vector2(100, 0)
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "gt", "value": "50"})
	var r := eng.results()
	assert_true(r["ok"])
	assert_true(r["passed"])
	assert_eq(r["assertions"].size(), 1)
	# A failing assertion flips passed but keeps ok true.
	eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "lt", "value": "0"})
	assert_true(eng.results()["ok"])
	assert_false(eng.results()["passed"])
	root.free()

func test_results_ok_false_on_fatal() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	eng.execute({"type": "set_property", "path": "Ghost", "properties": {}})  # fatal
	var r := eng.results()
	assert_false(r["ok"])
	assert_false(r["passed"])
	root.free()
