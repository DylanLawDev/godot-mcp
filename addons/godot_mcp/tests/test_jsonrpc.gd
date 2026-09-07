extends "res://addons/godot_mcp/tests/test_case.gd"

const JsonRpc = preload("res://addons/godot_mcp/jsonrpc.gd")

func test_parse_request_with_id() -> void:
	var r := JsonRpc.parse('{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}')
	assert_true(r["ok"], str(r))
	assert_eq(r["id"], 7)
	assert_eq(typeof(r["id"]), TYPE_INT, "Numeric request IDs must serialize as integers")
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

func test_parsed_id_round_trips_as_integer_in_success_and_error() -> void:
	for id in [0, 1, -7, 2147483648]:
		var request := '{"jsonrpc":"2.0","id":%d,"method":"ping"}' % id
		var parsed := JsonRpc.parse(request)
		var success := JSON.stringify(JsonRpc.result(parsed["id"], {}))
		var failure := JSON.stringify(JsonRpc.error(parsed["id"], -32601, "Method not found"))
		var expected := '"id":%d,' % id
		assert_true(success.contains(expected), success)
		assert_true(failure.contains(expected), failure)

func test_string_id_is_preserved() -> void:
	var parsed := JsonRpc.parse('{"jsonrpc":"2.0","id":"001","method":"ping"}')
	assert_eq(parsed["id"], "001")
	assert_true(JSON.stringify(JsonRpc.result(parsed["id"], {})).contains('"id":"001"'))

func test_error_envelope() -> void:
	var env := JsonRpc.error(null, -32601, "Method not found")
	assert_eq(env["jsonrpc"], "2.0")
	assert_eq(env["id"], null)
	assert_eq(env["error"]["code"], -32601)
	assert_eq(env["error"]["message"], "Method not found")
