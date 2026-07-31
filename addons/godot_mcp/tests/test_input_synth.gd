extends "res://addons/godot_mcp/tests/test_case.gd"

const InputSynth = preload("res://addons/godot_mcp/runtime/input_synth.gd")

# --- key events ---

func test_key_by_name() -> void:
	var r := InputSynth.build({"kind": "key", "key": "Left"})
	assert_true(r["ok"])
	var ev: InputEventKey = r["event"]
	assert_eq(ev.keycode, KEY_LEFT)
	assert_eq(ev.physical_keycode, KEY_LEFT)
	assert_true(ev.pressed)
	assert_false(ev.echo)

func test_key_constant_spelling() -> void:
	var r := InputSynth.build({"kind": "key", "key": "KEY_ESCAPE"})
	assert_true(r["ok"])
	assert_eq((r["event"] as InputEventKey).keycode, KEY_ESCAPE)

func test_key_release_and_echo() -> void:
	var r := InputSynth.build({"kind": "key", "key": "A", "pressed": false})
	assert_true(r["ok"])
	assert_false((r["event"] as InputEventKey).pressed)
	var e := InputSynth.build({"kind": "key", "key": "A", "echo": true})
	assert_true((e["event"] as InputEventKey).echo)

func test_key_printable_carries_unicode() -> void:
	var r := InputSynth.build({"kind": "key", "key": "A"})
	assert_eq((r["event"] as InputEventKey).unicode, int(KEY_A))
	# Non-printable keys carry no unicode; releases carry none either.
	var f := InputSynth.build({"kind": "key", "key": "F1"})
	assert_eq((f["event"] as InputEventKey).unicode, 0)
	var rel := InputSynth.build({"kind": "key", "key": "A", "pressed": false})
	assert_eq((rel["event"] as InputEventKey).unicode, 0)

func test_key_modifiers() -> void:
	var r := InputSynth.build({"kind": "key", "key": "S", "modifiers": ["ctrl", "shift"]})
	var ev: InputEventKey = r["event"]
	assert_true(ev.ctrl_pressed)
	assert_true(ev.shift_pressed)
	assert_false(ev.alt_pressed)
	assert_false(ev.meta_pressed)

func test_key_unknown_name_rejected() -> void:
	var r := InputSynth.build({"kind": "key", "key": "NotAKey"})
	assert_false(r["ok"])
	assert_has(r["error"], "Unknown key name")

func test_key_missing_name_rejected() -> void:
	assert_false(InputSynth.build({"kind": "key"})["ok"])

# --- mouse button events ---

func test_mouse_button_press_at_position() -> void:
	var r := InputSynth.build({"kind": "mouse_button", "button": "left", "position": [10, 20]})
	assert_true(r["ok"])
	var ev: InputEventMouseButton = r["event"]
	assert_eq(ev.button_index, MOUSE_BUTTON_LEFT)
	assert_true(ev.pressed)
	assert_eq(ev.position, Vector2(10, 20))
	assert_eq(ev.global_position, Vector2(10, 20))

func test_mouse_button_names() -> void:
	for pair in [["right", MOUSE_BUTTON_RIGHT], ["middle", MOUSE_BUTTON_MIDDLE], ["wheel_up", MOUSE_BUTTON_WHEEL_UP]]:
		var r := InputSynth.build({"kind": "mouse_button", "button": pair[0]})
		assert_true(r["ok"])
		assert_eq((r["event"] as InputEventMouseButton).button_index, pair[1])

func test_mouse_button_double_click() -> void:
	var r := InputSynth.build({"kind": "mouse_button", "button": "left", "double_click": true})
	assert_true((r["event"] as InputEventMouseButton).double_click)

func test_mouse_button_unknown_rejected() -> void:
	var r := InputSynth.build({"kind": "mouse_button", "button": "side"})
	assert_false(r["ok"])
	assert_has(r["error"], "Unknown mouse button")

func test_mouse_button_bad_position_rejected() -> void:
	assert_false(InputSynth.build({"kind": "mouse_button", "button": "left", "position": [1]})["ok"])
	assert_false(InputSynth.build({"kind": "mouse_button", "button": "left", "position": "x"})["ok"])
	assert_false(InputSynth.build({"kind": "mouse_button", "button": "left", "position": ["a", "b"]})["ok"])

# --- mouse motion events ---

func test_mouse_motion_fields() -> void:
	var r := InputSynth.build({"kind": "mouse_motion", "position": [5, 6], "relative": [1, -2], "velocity": [100, 0]})
	assert_true(r["ok"])
	var ev: InputEventMouseMotion = r["event"]
	assert_eq(ev.position, Vector2(5, 6))
	assert_eq(ev.relative, Vector2(1, -2))
	assert_eq(ev.velocity, Vector2(100, 0))

func test_mouse_motion_defaults_ok() -> void:
	# All fields optional: a bare motion event is still valid.
	assert_true(InputSynth.build({"kind": "mouse_motion"})["ok"])

func test_mouse_motion_bad_relative_rejected() -> void:
	assert_false(InputSynth.build({"kind": "mouse_motion", "relative": [1, 2, 3]})["ok"])

# --- action events ---

func test_action_event() -> void:
	var r := InputSynth.build({"kind": "action", "action": "ui_accept", "strength": 0.5})
	assert_true(r["ok"])
	var ev: InputEventAction = r["event"]
	assert_eq(ev.action, &"ui_accept")
	assert_true(ev.pressed)
	assert_eq(ev.strength, 0.5)

func test_action_strength_clamped() -> void:
	var r := InputSynth.build({"kind": "action", "action": "ui_accept", "strength": 7.0})
	assert_eq((r["event"] as InputEventAction).strength, 1.0)

func test_action_unknown_rejected() -> void:
	var r := InputSynth.build({"kind": "action", "action": "no_such_action"})
	assert_false(r["ok"])
	assert_has(r["error"], "No such input action")

func test_action_missing_rejected() -> void:
	assert_false(InputSynth.build({"kind": "action"})["ok"])

# --- dispatch-level shape ---

func test_unknown_kind_rejected() -> void:
	var r := InputSynth.build({"kind": "gamepad"})
	assert_false(r["ok"])
	assert_has(r["error"], "Unknown input_event kind")

func test_missing_kind_rejected() -> void:
	assert_false(InputSynth.build({})["ok"])

# --- button_mask tracking (mouse chords / drags) ---
# build() reads Input.get_mouse_button_mask() so masks reflect earlier
# synthesized presses. These tests drive Input directly to control that state.

func test_mouse_button_press_carries_own_mask_bit() -> void:
	var r := InputSynth.build({"kind": "mouse_button", "button": "right"})
	assert_eq(int((r["event"] as InputEventMouseButton).button_mask), MOUSE_BUTTON_MASK_RIGHT)
	var x := InputSynth.build({"kind": "mouse_button", "button": "xbutton1"})
	assert_eq(int((x["event"] as InputEventMouseButton).button_mask), MOUSE_BUTTON_MASK_MB_XBUTTON1)

func test_mouse_button_mask_accumulates_held_buttons() -> void:
	# Hold left (via the Input singleton, as the engine's dispatch would)...
	var left := InputSynth.build({"kind": "mouse_button", "button": "left"})
	Input.parse_input_event(left["event"])
	Input.flush_buffered_events()
	# ...then a right press must carry BOTH bits.
	var r := InputSynth.build({"kind": "mouse_button", "button": "right"})
	assert_eq(int((r["event"] as InputEventMouseButton).button_mask), MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT)
	# ...and a left release drops only the left bit (right isn't held in Input).
	var rel := InputSynth.build({"kind": "mouse_button", "button": "left", "pressed": false})
	assert_eq(int((rel["event"] as InputEventMouseButton).button_mask), 0)
	Input.parse_input_event(rel["event"])
	Input.flush_buffered_events()
	assert_false(Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT))

func test_mouse_motion_carries_held_mask() -> void:
	var press := InputSynth.build({"kind": "mouse_button", "button": "left", "position": [1, 1]})
	Input.parse_input_event(press["event"])
	Input.flush_buffered_events()
	var m := InputSynth.build({"kind": "mouse_motion", "position": [9, 9]})
	assert_eq(int((m["event"] as InputEventMouseMotion).button_mask), MOUSE_BUTTON_MASK_LEFT)
	var rel := InputSynth.build({"kind": "mouse_button", "button": "left", "pressed": false})
	Input.parse_input_event(rel["event"])
	Input.flush_buffered_events()
	var m2 := InputSynth.build({"kind": "mouse_motion", "position": [9, 9]})
	assert_eq(int((m2["event"] as InputEventMouseMotion).button_mask), 0)

func test_wheel_button_keeps_held_mask_unchanged() -> void:
	var press := InputSynth.build({"kind": "mouse_button", "button": "left"})
	Input.parse_input_event(press["event"])
	Input.flush_buffered_events()
	var w := InputSynth.build({"kind": "mouse_button", "button": "wheel_up"})
	assert_eq(int((w["event"] as InputEventMouseButton).button_mask), MOUSE_BUTTON_MASK_LEFT)
	var rel := InputSynth.build({"kind": "mouse_button", "button": "left", "pressed": false})
	Input.parse_input_event(rel["event"])
	Input.flush_buffered_events()
