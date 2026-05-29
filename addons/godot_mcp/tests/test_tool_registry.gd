extends "res://addons/godot_mcp/tests/test_case.gd"

const ToolRegistry = preload("res://addons/godot_mcp/tool_registry.gd")

func _echo_tool(args: Dictionary) -> Dictionary:
	return {"ok": true, "value": {"echoed": args.get("msg", "")}}

func _string_tool(_args: Dictionary) -> Dictionary:
	return {"ok": true, "value": "plain text"}

func _failing_tool(_args: Dictionary) -> Dictionary:
	return {"ok": false, "error": "boom"}

func _make_registry() -> RefCounted:
	var reg = ToolRegistry.new()
	reg.register("echo", "Echo the input", {"type": "object"}, Callable(self, "_echo_tool"))
	reg.register("stringy", "Returns a string", {"type": "object"}, Callable(self, "_string_tool"))
	reg.register("boom", "Always fails", {"type": "object"}, Callable(self, "_failing_tool"))
	return reg

func test_list_tools_exposes_schema() -> void:
	var tools = _make_registry().list_tools()
	assert_eq(tools.size(), 3)
	assert_eq(tools[0]["name"], "echo")
	assert_eq(tools[0]["description"], "Echo the input")
	assert_eq(tools[0]["inputSchema"], {"type": "object"})

func test_call_tool_wraps_dict_value_as_json_text() -> void:
	var res = _make_registry().call_tool("echo", {"msg": "hi"})
	assert_false(res["isError"])
	assert_eq(res["content"][0]["type"], "text")
	assert_eq(res["content"][0]["text"], '{"echoed":"hi"}')

func test_call_tool_passes_string_value_through() -> void:
	var res = _make_registry().call_tool("stringy", {})
	assert_eq(res["content"][0]["text"], "plain text")
	assert_false(res["isError"])

func test_call_tool_error_sets_is_error() -> void:
	var res = _make_registry().call_tool("boom", {})
	assert_true(res["isError"])
	assert_eq(res["content"][0]["text"], "boom")

func test_call_unknown_tool() -> void:
	var res = _make_registry().call_tool("nope", {})
	assert_true(res["isError"])
	assert_has(res["content"][0]["text"], "Unknown tool")
