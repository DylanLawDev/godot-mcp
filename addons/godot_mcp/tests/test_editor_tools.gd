extends "res://addons/godot_mcp/tests/test_case.gd"

const OutputCapture = preload("res://addons/godot_mcp/tools/output_capture.gd")

# --- 4.1: output_capture ring-buffer logger ---

func test_capture_records_log_and_error() -> void:
	var cap = OutputCapture.new()
	cap._log_message("hello", false)
	cap._log_error("f", "file.gd", 10, "boom", false, false, Logger.ERROR_TYPE_SCRIPT, [])
	var es := cap.entries()
	assert_eq(es.size(), 2)
	assert_eq(es[0]["type"], "log")
	assert_eq(es[0]["text"], "hello")
	assert_eq(es[0]["error"], false)
	assert_eq(es[1]["type"], "error")
	assert_eq(es[1]["line"], 10)
	assert_eq(es[1]["message"], "boom")
	assert_eq(es[1]["error_type"], Logger.ERROR_TYPE_SCRIPT)

func test_capture_errors_only_filters() -> void:
	var cap = OutputCapture.new()
	cap._log_message("hello", false)
	cap._log_error("f", "file.gd", 10, "boom", false, false, Logger.ERROR_TYPE_ERROR, [])
	var es := cap.entries(0, true)
	assert_eq(es.size(), 1)
	assert_eq(es[0]["type"], "error")

func test_capture_ring_eviction() -> void:
	var cap = OutputCapture.new()
	cap.cap = 4
	for i in range(6):
		cap._log_message("m%d" % i, false)
	var es := cap.entries()
	assert_eq(es.size(), 4)
	assert_eq(es[0]["text"], "m2")
	assert_eq(es[3]["text"], "m5")

func test_capture_clear_empties() -> void:
	var cap = OutputCapture.new()
	cap._log_message("a", false)
	cap.clear()
	assert_eq(cap.entries().size(), 0)

func test_capture_limit_returns_last_n() -> void:
	var cap = OutputCapture.new()
	for i in range(5):
		cap._log_message("m%d" % i, false)
	var es := cap.entries(2)
	assert_eq(es.size(), 2)
	assert_eq(es[0]["text"], "m3")
	assert_eq(es[1]["text"], "m4")
