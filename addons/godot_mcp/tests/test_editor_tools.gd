extends "res://addons/godot_mcp/tests/test_case.gd"

const OutputCapture = preload("res://addons/godot_mcp/tools/output_capture.gd")
const EditorTools = preload("res://addons/godot_mcp/tools/editor_tools.gd")

const CAPTURE_META := "GodotMCPOutputCapture"

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

# Review fix (PR #8): printerr()/stderr output reaches the logger as a log entry with
# error == true; errors-only must keep it, not just _log_error ("error" type) entries.
func test_capture_errors_only_includes_stderr_logs() -> void:
	var cap = OutputCapture.new()
	cap._log_message("plain", false)       # ordinary stdout: excluded
	cap._log_message("oops", true)         # printerr/stderr: included
	cap._log_error("f", "file.gd", 10, "boom", false, false, Logger.ERROR_TYPE_ERROR, [])
	var es := cap.entries(0, true)
	assert_eq(es.size(), 2)
	var texts := []
	for e in es:
		texts.append(e.get("text", e.get("message", "")))
	assert_has(texts, "oops")

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

# --- 4.3: editor_tools (headless: no plugin meta present) ---

func test_get_output_log_headless() -> void:
	var ed = EditorTools.new()
	var r := ed.get_output_log({})
	assert_true(r["ok"])
	assert_eq(r["value"]["entries"], [])

func test_clear_output_headless() -> void:
	var ed = EditorTools.new()
	var r := ed.clear_output({})
	assert_true(r["ok"])
	assert_eq(r["value"]["cleared"], false)

func test_get_editor_errors_headless() -> void:
	var ed = EditorTools.new()
	var r := ed.get_editor_errors({})
	assert_true(r["ok"])
	assert_eq(r["value"]["errors"], [])

func test_get_editor_screenshot_headless() -> void:
	var ed = EditorTools.new()
	var r := ed.get_editor_screenshot({})
	assert_false(r["ok"])
	assert_eq(r["error"], "Screenshots require a windowed editor")

func test_reload_project_headless() -> void:
	var ed = EditorTools.new()
	var r := ed.reload_project({})
	assert_true(r["ok"])
	assert_eq(r["value"]["reloaded"], false)

# --- 4.3: pass-through via injected capture in meta ---

func test_output_log_reads_injected_capture() -> void:
	var cap = OutputCapture.new()
	cap._log_message("alpha", false)
	cap._log_error("f", "file.gd", 3, "bad", false, false, Logger.ERROR_TYPE_ERROR, [])
	Engine.set_meta(CAPTURE_META, cap)
	var ed = EditorTools.new()
	var log_r := ed.get_output_log({})
	var err_r := ed.get_editor_errors({})
	Engine.remove_meta(CAPTURE_META)
	assert_eq(log_r["value"]["entries"].size(), 2)
	assert_eq(err_r["value"]["errors"].size(), 1)
	assert_eq(err_r["value"]["errors"][0]["message"], "bad")

func test_clear_output_clears_injected_capture() -> void:
	var cap = OutputCapture.new()
	cap._log_message("alpha", false)
	Engine.set_meta(CAPTURE_META, cap)
	var ed = EditorTools.new()
	var r := ed.clear_output({})
	var after := ed.get_output_log({})
	Engine.remove_meta(CAPTURE_META)
	assert_true(r["ok"])
	assert_eq(r["value"]["cleared"], true)
	assert_eq(after["value"]["entries"].size(), 0)

# Review fix (PR #10): ERR_FAIL_COND_MSG-style errors carry the actionable text in
# `rationale` while `code` is just the failed condition. Capture rationale so
# get_editor_errors surfaces the explanation, not only the condition.
func test_capture_records_rationale() -> void:
	var cap = OutputCapture.new()
	cap._log_error("f", "file.gd", 7, "Condition \"x\" is true.", "x must be set first", false, Logger.ERROR_TYPE_ERROR, [])
	var es := cap.entries()
	assert_eq(es[0]["message"], "Condition \"x\" is true.")
	assert_eq(es[0]["rationale"], "x must be set first")
