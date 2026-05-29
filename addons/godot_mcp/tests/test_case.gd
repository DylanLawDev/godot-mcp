extends SceneTree
# Base test case. A concrete test file does:
#   extends "res://addons/godot_mcp/tests/test_case.gd"
# and defines methods named test_*. Each is auto-run.
# Run a single suite:
#   godot4 --headless --path . --script addons/godot_mcp/tests/test_foo.gd
# Exit code is non-zero if any assertion failed.

var _passed := 0
var _failed := 0
var _cur := ""

func _init() -> void:
	for m in get_method_list():
		var n: String = m["name"]
		if n.begins_with("test_"):
			_cur = n
			call(n)
	print("=== %d passed, %d failed (%s) ===" % [_passed, _failed, _suite_name()])
	quit(1 if _failed > 0 else 0)

func _suite_name() -> String:
	return (get_script().resource_path as String).get_file()

func _fail(detail: String) -> void:
	_failed += 1
	printerr("  FAIL [%s] %s" % [_cur, detail])

func assert_true(cond: bool, msg := "") -> void:
	if cond: _passed += 1
	else: _fail("assert_true failed. " + msg)

func assert_false(cond: bool, msg := "") -> void:
	if not cond: _passed += 1
	else: _fail("assert_false failed. " + msg)

func assert_eq(actual, expected, msg := "") -> void:
	if actual == expected: _passed += 1
	else: _fail("assert_eq failed: expected %s but got %s. %s" % [str(expected), str(actual), msg])

func assert_ne(actual, unexpected, msg := "") -> void:
	if actual != unexpected: _passed += 1
	else: _fail("assert_ne failed: did not expect %s. %s" % [str(unexpected), msg])

func assert_has(haystack, needle, msg := "") -> void:
	if needle in haystack: _passed += 1
	else: _fail("assert_has failed: %s not in %s. %s" % [str(needle), str(haystack), msg])
