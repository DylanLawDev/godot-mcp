extends "res://addons/godot_mcp/tests/test_case.gd"

const InputTools = preload("res://addons/godot_mcp/tools/input_tools.gd")

# --- 5.1: get_input_actions ---

func test_get_input_actions_returns_actions() -> void:
	var input = InputTools.new()
	var r = input.get_input_actions({})
	assert_true(r["ok"], str(r))
	var actions: Array = r["value"]["actions"]
	assert_true(actions.size() > 0, "expected non-empty actions list")
	var names := []
	for a in actions:
		assert_true(a.has("name"))
		assert_true(a.has("deadzone"))
		assert_true(a.has("events"))
		names.append(a["name"])
	assert_has(names, "ui_accept")

func test_encode_action_pure() -> void:
	var input = InputTools.new()
	var enc = input._encode_action("input/jump", {"deadzone": 0.2, "events": []})
	assert_eq(enc["name"], "jump")
	assert_eq(enc["deadzone"], 0.2)
	assert_eq(enc["events"], [])
