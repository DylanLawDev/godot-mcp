extends "res://addons/godot_mcp/tests/test_case.gd"
const Sequence = preload("res://addons/godot_mcp/runtime/input_sequence.gd")
func test_low_tick_rate_sequence_gets_sufficient_deadline() -> void:
	assert_eq(Sequence.timeout_for_frames(600, 10), 70.0)
	assert_eq(Sequence.timeout_for_frames(600, 1), 610.0)
	assert_eq(Sequence.timeout_for_frames(600, 60), 30.0)
	assert_eq(Sequence.timeout_for_events([{"wait_frames": 300}, {"hold_frames": 300}], 10), 70.0)
	assert_eq(Sequence.timeout_for_events([{"hold_frames": "bad"}], 10), 30.0)
