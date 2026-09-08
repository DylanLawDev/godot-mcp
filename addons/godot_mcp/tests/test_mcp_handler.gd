extends "res://addons/godot_mcp/tests/test_case.gd"

const McpHandler = preload("res://addons/godot_mcp/mcp_handler.gd")
const ToolRegistry = preload("res://addons/godot_mcp/tool_registry.gd")

func _parse(text: String) -> Dictionary:
	return JSON.parse_string(text)

func test_initialize_returns_server_info_and_capabilities() -> void:
	var h = McpHandler.new()
	var out := h.handle_message('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}')
	var d := _parse(out)
	assert_eq(d["id"], 1)
	assert_eq(d["result"]["protocolVersion"], "2025-06-18")
	assert_true(d["result"]["capabilities"].has("tools"))
	assert_eq(d["result"]["serverInfo"]["name"], "godot-mcp")

func test_initialize_defaults_protocol_version_when_absent() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}'))
	assert_eq(d["result"]["protocolVersion"], McpHandler.PROTOCOL_VERSION)

func test_legacy_initialize_never_echoes_unknown_or_modern_version() -> void:
	var h = McpHandler.new()
	for requested in ["unknown", McpHandler.MODERN_PROTOCOL_VERSION]:
		var body := JSON.stringify({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"protocolVersion": requested}})
		var d := _parse(h.handle_message(body))
		assert_eq(d["result"]["protocolVersion"], McpHandler.LEGACY_PROTOCOL_VERSION)

func test_notification_initialized_returns_empty_string() -> void:
	var h = McpHandler.new()
	assert_eq(h.handle_message('{"jsonrpc":"2.0","method":"notifications/initialized"}'), "")

func test_ping_returns_empty_result_object() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":3,"method":"ping"}'))
	assert_eq(d["result"], {})

func test_tools_list_includes_file_and_script_tools() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}'))
	var names := []
	for t in d["result"]["tools"]:
		names.append(t["name"])
	for expected in ["read_file", "list_dir", "search_project", "create_script", "edit_script", "validate_script"]:
		assert_has(names, expected)

# Guards against registration drift: the default registry exposes exactly the
# documented editor core plus explicitly listed runtime tools, all distinct.
func test_tools_list_exposes_all_distinct_tools() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":40,"method":"tools/list","params":{}}'))
	var names := {}
	for t in d["result"]["tools"]:
		names[t["name"]] = true
	var runtime_names := ["run_project", "get_run_status", "stop_project", "capture_game_frame", "send_input", "resize_game_window", "get_runtime_tree", "get_runtime_properties", "get_runtime_errors", "run_scenario", "get_scenario_result", "get_simulation_snapshot", "advance_ticks", "sample_performance", "validate_project", "export_build"]
	var expected_count := 40 + runtime_names.size()
	assert_eq(d["result"]["tools"].size(), expected_count, "tool count drifted")
	assert_eq(names.size(), expected_count, "duplicate tool name registered")
	for name in runtime_names:
		assert_has(names, name)

func test_tools_call_read_file_round_trip() -> void:
	var f := FileAccess.open("res://_mcp_handler_test.txt", FileAccess.WRITE)
	f.store_string("payload")
	f = null
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"_mcp_handler_test.txt"}}}'))
	assert_false(d["result"]["isError"])
	assert_eq(d["result"]["content"][0]["text"], "payload")
	DirAccess.remove_absolute("res://_mcp_handler_test.txt")

func test_unknown_method_returns_error() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":6,"method":"does/not/exist","params":{}}'))
	assert_eq(d["error"]["code"], -32601)

func test_invalid_json_returns_parse_error() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message("{not json"))
	assert_eq(d["error"]["code"], -32700)
	assert_true(d.has("id"), "JSON-RPC 2.0 error responses always carry id")
	assert_eq(d["id"], null)

func test_invalid_envelopes_return_specific_errors() -> void:
	var h = McpHandler.new()
	var invalid_request := _parse(h.handle_message('[1,2,3]'))
	assert_eq(invalid_request["error"]["code"], -32600)
	assert_eq(invalid_request["id"], null)
	var bad_method := _parse(h.handle_message('{"jsonrpc":"2.0","id":9,"method":7}'))
	assert_eq(bad_method["error"]["code"], -32600)
	assert_eq(bad_method["id"], 9)
	var invalid_params := _parse(h.handle_message('{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}'))
	assert_eq(invalid_params["error"]["code"], -32602)

func test_client_response_is_rejected() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":"r","result":{}}'))
	assert_eq(d["error"]["code"], -32600)

func test_request_only_operation_sent_as_notification_is_not_run() -> void:
	var h = McpHandler.new()
	assert_eq(h.handle_message('{"jsonrpc":"2.0","method":"tools/call","params":{"name":"clear_output","arguments":{}}}'), "")

func test_structured_dispatch_reports_status_and_body() -> void:
	var h = McpHandler.new()
	var accepted := h.handle_request('{"jsonrpc":"2.0","method":"notifications/initialized"}')
	assert_eq(accepted["status"], 202)
	assert_eq(accepted["body"], "")
	var malformed := h.handle_request("not-json")
	assert_eq(malformed["status"], 400)

func _modern_request(id, method: String, extra_params := {}, version := "2026-07-28") -> String:
	var params: Dictionary = extra_params.duplicate(true)
	params["_meta"] = {
		"io.modelcontextprotocol/protocolVersion": version,
		"io.modelcontextprotocol/clientCapabilities": {},
		"io.modelcontextprotocol/clientInfo": {"name": "test", "version": "1"},
	}
	return JSON.stringify({"jsonrpc": "2.0", "id": id, "method": method, "params": params})

func test_modern_support_is_disabled_by_default() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message(_modern_request(50, "server/discover")))
	assert_eq(d["error"]["code"], -32022)
	assert_eq(d["error"]["data"]["supported"], [McpHandler.LEGACY_PROTOCOL_VERSION])

func test_modern_discovery_reports_exact_supported_profile_when_enabled() -> void:
	var h = McpHandler.new(null, null, true)
	var d := _parse(h.handle_message(_modern_request("discover", "server/discover")))
	var result: Dictionary = d["result"]
	assert_eq(result["supportedVersions"], [McpHandler.LEGACY_PROTOCOL_VERSION, McpHandler.MODERN_PROTOCOL_VERSION])
	assert_eq(result["capabilities"], {"tools": {}, "resources": {}})
	assert_eq(result["resultType"], "complete")
	assert_eq(result["ttlMs"], 0)
	assert_eq(result["cacheScope"], "private")
	assert_eq(result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"], "godot-mcp")

func test_modern_metadata_is_required_and_validated_without_downgrade() -> void:
	var h = McpHandler.new(null, null, true)
	var no_meta := '{"jsonrpc":"2.0","id":50,"method":"server/discover","params":{}}'
	assert_eq(_parse(h.handle_message(no_meta))["error"]["code"], -32602)
	var missing_caps := '{"jsonrpc":"2.0","id":51,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}'
	assert_eq(_parse(h.handle_message(missing_caps))["error"]["code"], -32602)
	var malformed_info := _modern_request(52, "tools/list")
	var body: Dictionary = JSON.parse_string(malformed_info)
	body["params"]["_meta"]["io.modelcontextprotocol/clientInfo"] = {"name": 1, "version": "x"}
	assert_eq(_parse(h.handle_message(JSON.stringify(body)))["error"]["code"], -32602)

func test_unsupported_modern_version_has_requested_and_supported_details() -> void:
	var h = McpHandler.new(null, null, true)
	var d := _parse(h.handle_message(_modern_request(53, "tools/list", {}, "2099-01-01")))
	assert_eq(d["error"]["code"], -32022)
	assert_eq(d["error"]["data"]["requested"], "2099-01-01")

func test_interleaved_modern_and_legacy_requests_do_not_share_state() -> void:
	var h = McpHandler.new(null, null, true)
	assert_true(_parse(h.handle_message(_modern_request(54, "tools/list"))).has("result"))
	var legacy := _parse(h.handle_message('{"jsonrpc":"2.0","id":55,"method":"initialize","params":{"protocolVersion":"bogus"}}'))
	assert_eq(legacy["result"]["protocolVersion"], McpHandler.LEGACY_PROTOCOL_VERSION)
	assert_true(_parse(h.handle_message(_modern_request(56, "resources/list"))).has("result"))

func test_modern_initialize_does_not_take_legacy_dispatch_path() -> void:
	var h = McpHandler.new(null, null, true)
	for method in ["initialize", "ping"]:
		var d := _parse(h.handle_message(_modern_request(57, method)))
		assert_eq(d["error"]["code"], -32601, method)

func test_legacy_meta_without_protocol_version_stays_legacy() -> void:
	var h = McpHandler.new(null, null, true)
	var body := '{"jsonrpc":"2.0","id":58,"method":"tools/list","params":{"_meta":{"progressToken":"p1"}}}'
	var d := _parse(h.handle_message(body))
	assert_true(d.has("result"), str(d))
	assert_false(d["result"].has("resultType"))
	var non_string := '{"jsonrpc":"2.0","id":59,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":7}}}'
	assert_eq(_parse(h.handle_message(non_string))["error"]["code"], -32602)

func test_unidentified_error_id_follows_announced_protocol_era() -> void:
	var h = McpHandler.new(null, null, true)
	var legacy = h.handle_request("{not json")
	var legacy_body: Dictionary = _parse(legacy["body"])
	assert_true(legacy_body.has("id"))
	assert_eq(legacy_body["id"], null)
	var modern = h.handle_request("{not json", {"headers": {"mcp-protocol-version": McpHandler.MODERN_PROTOCOL_VERSION}})
	assert_eq(modern["status"], 400)
	assert_false(_parse(modern["body"]).has("id"))

func test_all_modern_success_results_have_result_type_and_server_identity() -> void:
	var h = McpHandler.new(null, null, true)
	var cases := [
		["server/discover", {}],
		["tools/list", {}],
		["tools/call", {"name": "get_project_info", "arguments": {}}],
		["tools/call", {"name": "does_not_exist", "arguments": {}}],
		["resources/list", {}],
		["resources/read", {"uri": "godot://project/info"}],
		["resources/templates/list", {}],
	]
	for case in cases:
		var d := _parse(h.handle_message(_modern_request(60, case[0], case[1])))
		assert_true(d.has("result"), case[0])
		assert_eq(d["result"]["resultType"], "complete", case[0])
		assert_eq(d["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["version"], McpHandler.SERVER_VERSION, case[0])

func test_modern_cacheable_results_are_private_and_immediately_stale() -> void:
	var h = McpHandler.new(null, null, true)
	for method in ["server/discover", "tools/list", "resources/list", "resources/read", "resources/templates/list"]:
		var params := {"uri": "godot://project/info"} if method == "resources/read" else {}
		var result: Dictionary = _parse(h.handle_message(_modern_request(61, method, params)))["result"]
		assert_eq(result["ttlMs"], 0, method)
		assert_true(result["ttlMs"] >= 0, method)
		assert_has(h.handle_message(_modern_request(61, method, params)), '"ttlMs":0', method)
		assert_eq(result["cacheScope"], "private", method)

func _deferred_tool(_args: Dictionary):
	_pending = ToolRegistry.Deferred.new()
	return _pending

var _pending

func test_modern_deferred_tool_result_is_decorated_on_completion() -> void:
	var reg = ToolRegistry.new()
	reg.register("later", "deferred", {"type": "object"}, Callable(self, "_deferred_tool"))
	var h = McpHandler.new(reg, null, true)
	var out = h.handle_request(_modern_request(64, "tools/call", {"name": "later", "arguments": {}}))
	assert_true(out is ToolRegistry.Deferred)
	_pending.resolve({"ok": true, "value": "done"})
	var response: Dictionary = out.value
	assert_eq(response["status"], 200)
	var d := _parse(response["body"])
	assert_eq(d["id"], 64)
	assert_false(d["result"]["isError"])
	assert_eq(d["result"]["resultType"], "complete")
	assert_eq(d["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"], "godot-mcp")
	assert_false(d["result"].has("ttlMs"))

func test_modern_jsonrpc_errors_are_not_decorated() -> void:
	var h = McpHandler.new(null, null, true)
	var d := _parse(h.handle_message(_modern_request(62, "resources/read", {"uri": "godot://missing"})))
	assert_true(d.has("error"))
	assert_false(d.has("result"))

func test_legacy_results_are_not_decorated() -> void:
	var h = McpHandler.new(null, null, true)
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":63,"method":"tools/list","params":{}}'))
	assert_false(d["result"].has("resultType"))


func test_initialize_advertises_resources_capability() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":10,"method":"initialize","params":{}}'))
	assert_true(d["result"]["capabilities"].has("resources"))

func test_tools_list_includes_project_tools() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":11,"method":"tools/list","params":{}}'))
	var names := []
	for t in d["result"]["tools"]:
		names.append(t["name"])
	for expected in ["get_project_settings", "list_project_resources", "get_project_info"]:
		assert_has(names, expected)

func test_resources_list_includes_project_info() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":12,"method":"resources/list","params":{}}'))
	var uris := []
	for r in d["result"]["resources"]:
		uris.append(r["uri"])
	assert_has(uris, "godot://project/info")

func test_resources_read_project_info_round_trip() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":13,"method":"resources/read","params":{"uri":"godot://project/info"}}'))
	var c = d["result"]["contents"][0]
	assert_eq(c["uri"], "godot://project/info")
	assert_eq(c["mimeType"], "application/json")
	var info = JSON.parse_string(c["text"])
	assert_eq(info["name"], "Godot MCP")

func test_resources_read_unknown_uri_errors() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":14,"method":"resources/read","params":{"uri":"godot://nope"}}'))
	assert_eq(d["error"]["code"], -32602)

func test_tools_list_includes_scene_tools() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":20,"method":"tools/list","params":{}}'))
	var names := []
	for t in d["result"]["tools"]:
		names.append(t["name"])
	for expected in ["get_scene_tree", "get_node_properties", "create_node", "delete_node", "modify_node"]:
		assert_has(names, expected)

func test_tools_call_get_scene_tree_reports_no_scene_headless() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"get_scene_tree","arguments":{}}}'))
	assert_true(d["result"]["isError"])
	assert_eq(d["result"]["content"][0]["text"], "No scene is currently open")

func test_resources_list_includes_current_scene_and_script() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":22,"method":"resources/list","params":{}}'))
	var uris := []
	for r in d["result"]["resources"]:
		uris.append(r["uri"])
	assert_has(uris, "godot://scene/current")
	assert_has(uris, "godot://script/current")

func test_resources_read_scene_current_closed_headless() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":23,"method":"resources/read","params":{"uri":"godot://scene/current"}}'))
	var c = d["result"]["contents"][0]
	assert_eq(c["uri"], "godot://scene/current")
	assert_eq(c["mimeType"], "application/json")
	var body = JSON.parse_string(c["text"])
	assert_eq(body["open"], false)
