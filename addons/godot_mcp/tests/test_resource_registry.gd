extends "res://addons/godot_mcp/tests/test_case.gd"

const ResourceRegistry = preload("res://addons/godot_mcp/resource_registry.gd")

# A stand-in handler object. Returns a fixed contract result.
class _Stub:
	var _result: Dictionary
	func _init(result: Dictionary) -> void:
		_result = result
	func handle(_args: Dictionary) -> Dictionary:
		return _result

func test_list_resources_returns_descriptors_without_handler() -> void:
	var reg = ResourceRegistry.new()
	var stub = _Stub.new({"ok": true, "value": "x"})
	reg.register("godot://a", "a_name", "desc", "application/json", Callable(stub, "handle"))
	var listed: Array = reg.list_resources()
	assert_eq(listed.size(), 1)
	assert_eq(listed[0]["uri"], "godot://a")
	assert_eq(listed[0]["name"], "a_name")
	assert_eq(listed[0]["mimeType"], "application/json")
	assert_false(listed[0].has("handler"))

func test_has_reports_registration() -> void:
	var reg = ResourceRegistry.new()
	var stub = _Stub.new({"ok": true, "value": ""})
	reg.register("godot://a", "a", "d", "text/plain", Callable(stub, "handle"))
	assert_true(reg.has("godot://a"))
	assert_false(reg.has("godot://missing"))

func test_read_resource_string_value_passes_through() -> void:
	var reg = ResourceRegistry.new()
	var stub = _Stub.new({"ok": true, "value": "hello"})
	reg.register("godot://a", "a", "d", "text/plain", Callable(stub, "handle"))
	var out: Dictionary = reg.read_resource("godot://a")
	assert_eq(out["contents"][0]["uri"], "godot://a")
	assert_eq(out["contents"][0]["mimeType"], "text/plain")
	assert_eq(out["contents"][0]["text"], "hello")

func test_read_resource_non_string_value_is_json_stringified() -> void:
	var reg = ResourceRegistry.new()
	var stub = _Stub.new({"ok": true, "value": {"k": 1}})
	reg.register("godot://a", "a", "d", "application/json", Callable(stub, "handle"))
	var out: Dictionary = reg.read_resource("godot://a")
	var parsed = JSON.parse_string(out["contents"][0]["text"])
	assert_eq(parsed["k"], 1)

func test_read_resource_error_returns_error_text() -> void:
	var reg = ResourceRegistry.new()
	var stub = _Stub.new({"ok": false, "error": "boom"})
	reg.register("godot://a", "a", "d", "text/plain", Callable(stub, "handle"))
	var out: Dictionary = reg.read_resource("godot://a")
	assert_eq(out["contents"][0]["text"], "boom")
