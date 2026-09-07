extends "res://addons/godot_mcp/tests/test_case.gd"

const McpHandler = preload("res://addons/godot_mcp/mcp_handler.gd")

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
	assert_false(d.has("id"))

func test_invalid_envelopes_return_specific_errors() -> void:
	var h = McpHandler.new()
	var invalid_request := _parse(h.handle_message('[1,2,3]'))
	assert_eq(invalid_request["error"]["code"], -32600)
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
