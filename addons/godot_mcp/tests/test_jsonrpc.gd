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
	assert_eq(r["error_code"], -32600)

func test_parse_validates_version_method_id_and_params() -> void:
	var cases := [
		['{"id":1,"method":"ping"}', -32600],
		['{"jsonrpc":"1.0","id":1,"method":"ping"}', -32600],
		['{"jsonrpc":"2.0","id":1,"method":7}', -32600],
		['{"jsonrpc":"2.0","id":null,"method":"ping"}', -32600],
		['{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}', -32602],
	]
	for case in cases:
		var parsed := JsonRpc.parse(case[0])
		assert_false(parsed["ok"], case[0])
		assert_eq(parsed["error_code"], case[1], case[0])

func test_client_response_is_classified_separately() -> void:
	var parsed := JsonRpc.parse('{"jsonrpc":"2.0","id":1,"result":{}}')
	assert_true(parsed["ok"], str(parsed))
	assert_eq(parsed["message_type"], "response")
	var invalid_id := JsonRpc.parse('{"jsonrpc":"2.0","id":{},"result":{}}')
	assert_false(invalid_id["ok"])
	assert_eq(invalid_id["error_code"], -32600)

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

func test_error_envelope_supports_data_and_optional_id() -> void:
	var env := JsonRpc.error(null, -32022, "Unsupported", {"supported": ["v"]}, false)
	assert_false(env.has("id"))
	assert_eq(env["error"]["data"]["supported"], ["v"])
