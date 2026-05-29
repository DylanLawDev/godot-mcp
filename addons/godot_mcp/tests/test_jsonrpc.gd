extends "res://addons/godot_mcp/tests/test_case.gd"

const JsonRpc = preload("res://addons/godot_mcp/jsonrpc.gd")

func test_parse_request_with_id() -> void:
	var r := JsonRpc.parse('{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}')
	assert_true(r["ok"], str(r))
	assert_eq(r["id"], 7)
	assert_eq(r["method"], "tools/list")
	assert_false(r["is_notification"])

func test_parse_notification_has_no_id() -> void:
	var r := JsonRpc.parse('{"jsonrpc":"2.0","method":"notifications/initialized"}')
	assert_true(r["ok"], str(r))
	assert_true(r["is_notification"])

func test_parse_params_default_empty_dict() -> void:
	var r := JsonRpc.parse('{"jsonrpc":"2.0","id":1,"method":"ping"}')
	assert_eq(r["params"], {})

func test_parse_invalid_json() -> void:
	var r := JsonRpc.parse("{not json")
	assert_false(r["ok"])

func test_parse_non_object() -> void:
	var r := JsonRpc.parse("[1,2,3]")
	assert_false(r["ok"])

func test_result_envelope() -> void:
	var env := JsonRpc.result(5, {"a": 1})
	assert_eq(env["jsonrpc"], "2.0")
	assert_eq(env["id"], 5)
	assert_eq(env["result"], {"a": 1})

func test_error_envelope() -> void:
	var env := JsonRpc.error(null, -32601, "Method not found")
	assert_eq(env["jsonrpc"], "2.0")
	assert_eq(env["id"], null)
	assert_eq(env["error"]["code"], -32601)
	assert_eq(env["error"]["message"], "Method not found")
