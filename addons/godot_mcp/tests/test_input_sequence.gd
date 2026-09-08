extends "res://addons/godot_mcp/tests/test_case.gd"
const Sequence = preload("res://addons/godot_mcp/runtime/input_sequence.gd")

func test_sequence_validates_entire_batch_and_bounds() -> void:
	assert_true(Sequence.validate([{"kind": "key", "key": "A", "hold_frames": 3}]).ok)
	for events in [[], null, [1], [{"kind": "key", "key": "A", "pressed": "false"}], [{"kind": "key", "key": "A", "wait_frames": 1, "hold_frames": 1}], [{"kind": "mouse_motion", "hold_frames": 1}], [{"kind": "key", "key": "A", "wait_frames": 601}], [{"kind": "key", "key": "A", "modifiers": ["bad"]}], [{"kind": "key", "key": "A"}, {"kind": "unknown"}]]:
		assert_false(Sequence.validate(events).ok)

func test_dispatch_tracks_and_releases_only_injected_holds() -> void:
	var sequence := Sequence.new(null)
	Input.action_press("ui_left")
	assert_true(sequence._dispatch({"kind": "key", "key": "A"}).ok)
	assert_eq(sequence._held.size(), 1)
	sequence.release_all()
	assert_eq(sequence._held.size(), 0)
	assert_false(Input.is_key_pressed(KEY_A))
	assert_true(Input.is_action_pressed("ui_left"))
	Input.action_release("ui_left")

func test_key_alias_release_removes_canonical_hold() -> void:
	var sequence := Sequence.new(null)
	sequence._dispatch({"kind": "key", "key": "A", "pressed": true})
	sequence._dispatch({"kind": "key", "key": " KEY_A ", "pressed": false})
	assert_eq(sequence._held.size(), 0)
	assert_false(Input.is_key_pressed(KEY_A))
	sequence.release_all()

func test_wheel_events_are_momentary() -> void:
	assert_false(Sequence.validate([{"kind": "mouse_button", "button": "wheel_up", "hold_frames": 1}]).ok)
	var sequence := Sequence.new(null)
	assert_true(sequence._dispatch({"kind": "mouse_button", "button": "wheel_up"}).ok)
	assert_eq(sequence._held.size(), 0)
	sequence.release_all()

func test_synthesized_releases_clear_press_only_flags() -> void:
	var mouse := {"kind": "mouse_button", "button": "left", "double_click": true, "position": [12, 34]}
	var mouse_event = Sequence.Synth.build(Sequence.release_item(mouse)).event
	assert_false(mouse_event.pressed)
	assert_false(mouse_event.double_click)
	assert_eq(mouse_event.position, Vector2(12, 34))
	assert_true(mouse.double_click)
	var key := {"kind": "key", "key": "A", "echo": true}
	var key_event = Sequence.Synth.build(Sequence.release_item(key)).event
	assert_false(key_event.pressed)
	assert_false(key_event.echo)
	assert_eq(key_event.keycode, KEY_A)
	assert_true(key.echo)
