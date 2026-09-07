extends "res://addons/godot_mcp/tests/test_case.gd"
const Capture = preload("res://addons/godot_mcp/tools/output_capture.gd")
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")

func test_capture_cursors_metadata_and_eviction() -> void:
	var capture := Capture.new()
	capture.cap = 2
	capture._log_error("tick", "res://game.gd", 9, "failure", "details", false, 0, [])
	capture._log_message("normal", false)
	var page := capture.entries_since(0, 1)
	assert_eq(page.entries.size(), 1)
	assert_eq(page.entries[0].function, "tick")
	assert_eq(page.entries[0].file, "res://game.gd")
	assert_eq(page.entries[0].line, 9)
	capture._log_message("stderr", true)
	assert_true(capture.entries_since(0).truncated)
	var next := capture.entries_since(page.next_sequence)
	assert_eq(next.entries.size(), 1)
	assert_eq(next.entries[0].text, "stderr")
	capture.clear()
	capture._log_message("later", true)
	assert_true(capture.entries_since(0).entries[0].sequence > next.next_sequence)

func test_retained_runtime_errors_paginate_without_clearing() -> void:
	var manager := Sessions.new()
	manager.sessions.a = {"state": "exited", "_errors": [], "_error_sequence": 0, "_source_gap": false}
	manager._record_error("a", {"source": "stderr", "text": "startup"})
	manager._record_error("a", {"source": "runtime_logger", "message": "runtime"})
	var first := manager.errors("a", 0, 1)
	assert_eq(first.value.entries[0].text, "startup")
	var second := manager.errors("a", first.value.next_sequence, 1)
	assert_eq(second.value.entries[0].message, "runtime")
	assert_eq(manager.errors("a", 0, 100).value.entries.size(), 2)
	assert_false(manager.errors("missing", 0, 100).ok)
	for i in 1001:
		manager._record_error("a", {"text": str(i)})
	assert_true(manager.errors("a", 0, 1).value.truncated)
	manager.shutdown()
