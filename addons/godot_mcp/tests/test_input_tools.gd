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

# Review fix (PR #9): feature-tag overrides (e.g. "input/fire.macos") are per-platform
# overrides of a base action, not standalone actions, and must not be reported. This
# test only mutates ProjectSettings in memory (never calls save()), so project.godot
# is untouched.
func test_get_input_actions_excludes_feature_overrides() -> void:
	var input = InputTools.new()
	ProjectSettings.set_setting("input/_mcp_feat", {"deadzone": 0.5, "events": []})
	ProjectSettings.set_setting("input/_mcp_feat.macos", {"deadzone": 0.5, "events": []})
	var got = input.get_input_actions({})
	var names := []
	for a in got["value"]["actions"]:
		names.append(a["name"])
	assert_has(names, "_mcp_feat")
	assert_false(names.has("_mcp_feat.macos"))
	# Cleanup: drop the in-memory settings (no save() was called, so disk is clean).
	ProjectSettings.set_setting("input/_mcp_feat", null)
	ProjectSettings.set_setting("input/_mcp_feat.macos", null)

func test_encode_action_pure() -> void:
	var input = InputTools.new()
	var enc = input._encode_action("input/jump", {"deadzone": 0.2, "events": []})
	assert_eq(enc["name"], "jump")
	assert_eq(enc["deadzone"], 0.2)
	assert_eq(enc["events"], [])

# --- 5.2: set_input_action ---

func test_build_action_deadzone_only_keeps_events() -> void:
	var input = InputTools.new()
	var ev := InputEventKey.new()
	ev.keycode = KEY_SPACE
	var existing := {"deadzone": 0.5, "events": [ev]}
	var res = input._build_action(existing, {"deadzone": 0.9})
	assert_eq(res["action"]["deadzone"], 0.9)
	assert_eq(res["action"]["events"].size(), 1)
	assert_eq(res["errors"], [])

func test_build_action_parses_valid_event() -> void:
	var input = InputTools.new()
	var ev := InputEventKey.new()
	ev.keycode = KEY_A
	var s := var_to_str(ev)
	var res = input._build_action({"deadzone": 0.5, "events": []}, {"events": [s]})
	assert_eq(res["action"]["events"].size(), 1)
	assert_true(res["action"]["events"][0] is InputEvent)
	assert_eq(res["errors"], [])

func test_build_action_rejects_invalid_event() -> void:
	var input = InputTools.new()
	# A non-InputEvent var_to_str string (a plain int) must be rejected.
	var res = input._build_action({"deadzone": 0.5, "events": []}, {"events": ["42"]})
	assert_eq(res["action"]["events"].size(), 0)
	assert_eq(res["errors"].size(), 1)

func test_set_input_action_rejects_bad_names() -> void:
	var input = InputTools.new()
	assert_false(input.set_input_action({"name": ""})["ok"])
	assert_false(input.set_input_action({"name": "  "})["ok"])
	assert_false(input.set_input_action({"name": "foo/bar"})["ok"])
	# project.godot config / namespace metacharacters are rejected too.
	assert_false(input.set_input_action({"name": "foo=bar"})["ok"])
	assert_false(input.set_input_action({"name": "foo\nbar"})["ok"])
	assert_false(input.set_input_action({"name": "[evil]"})["ok"])
	# A non-numeric deadzone is rejected rather than silently coerced to 0.0.
	assert_false(input.set_input_action({"name": "ok_name", "deadzone": "abc"})["ok"])

func test_set_input_action_integration() -> void:
	var input = InputTools.new()
	var key := "input/_mcp_test_action"
	# Snapshot the on-disk project file so teardown can restore it byte-for-byte.
	# ProjectSettings.save() reformats the file (adds a header), so removing the
	# action alone leaves project.godot dirty; restoring the original bytes does not.
	var original := FileAccess.get_file_as_bytes("res://project.godot")
	var r = input.set_input_action({"name": "_mcp_test_action", "deadzone": 0.3})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"]["name"], "_mcp_test_action")
	assert_eq(r["value"]["deadzone"], 0.3)
	# Now it should show up in get_input_actions.
	var got = input.get_input_actions({})
	var names := []
	for a in got["value"]["actions"]:
		names.append(a["name"])
	assert_has(names, "_mcp_test_action")
	# TEARDOWN: drop the action from the live ProjectSettings and restore the
	# original project.godot bytes so the working tree is left clean.
	ProjectSettings.set_setting(key, null)
	var f := FileAccess.open("res://project.godot", FileAccess.WRITE)
	f.store_buffer(original)
	f = null
