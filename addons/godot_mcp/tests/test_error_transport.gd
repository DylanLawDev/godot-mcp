extends "res://addons/godot_mcp/tests/test_case.gd"
const Bridge = preload("res://addons/godot_mcp/runtime/game_bridge.gd")
func test_large_error_does_not_block_following_error() -> void:
	var batch := {"entries": [{"sequence": 1, "message": "😀".repeat(20000)}, {"sequence": 2, "message": "later"}], "next_sequence": 2, "truncated": false}
	var fitted := Bridge.fit_error_batch(batch)
	assert_true(fitted.truncated)
	assert_true(fitted.entries[0].truncated)
	assert_true(JSON.stringify(fitted.entries[0]).to_utf8_buffer().size() < 64 * 1024)
	assert_eq(fitted.entries[1].message, "later")
	assert_eq(fitted.next_sequence, 2)
	assert_false(batch.truncated)
