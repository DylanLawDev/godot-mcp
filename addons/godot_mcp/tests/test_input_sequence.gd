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
