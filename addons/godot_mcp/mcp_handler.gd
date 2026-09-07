@tool
extends RefCounted

const JsonRpc = preload("res://addons/godot_mcp/jsonrpc.gd")
const ToolRegistry = preload("res://addons/godot_mcp/tool_registry.gd")
const FileTools = preload("res://addons/godot_mcp/tools/file_tools.gd")
const ScriptTools = preload("res://addons/godot_mcp/tools/script_tools.gd")
const ProjectTools = preload("res://addons/godot_mcp/tools/project_tools.gd")
const SceneTools = preload("res://addons/godot_mcp/tools/scene_tools.gd")
const EditorTools = preload("res://addons/godot_mcp/tools/editor_tools.gd")
const InputTools = preload("res://addons/godot_mcp/tools/input_tools.gd")
const BuildTools = preload("res://addons/godot_mcp/tools/build_tools.gd")
const ScenarioTools = preload("res://addons/godot_mcp/tools/scenario_tools.gd")
const RuntimeTools = preload("res://addons/godot_mcp/tools/runtime_tools.gd")
const UidTools = preload("res://addons/godot_mcp/tools/uid_tools.gd")
const ResourceRegistry = preload("res://addons/godot_mcp/resource_registry.gd")

const LEGACY_PROTOCOL_VERSION := "2025-06-18"
const MODERN_PROTOCOL_VERSION := "2026-07-28"
const PROTOCOL_VERSION := LEGACY_PROTOCOL_VERSION
const SERVER_NAME := "godot-mcp"
const SERVER_VERSION := "0.2.0"
const META_PROTOCOL_VERSION := "io.modelcontextprotocol/protocolVersion"
const META_CLIENT_CAPABILITIES := "io.modelcontextprotocol/clientCapabilities"
const META_CLIENT_INFO := "io.modelcontextprotocol/clientInfo"

var _registry
var _resources
var _modern_enabled: bool

func _init(registry = null, resources = null, modern_enabled := true) -> void:
	var project = ProjectTools.new()
	var scene = SceneTools.new()
	_registry = registry if registry != null else _build_default_registry(project, scene)
	_resources = resources if resources != null else _build_default_resource_registry(project, scene)
	_modern_enabled = modern_enabled

# Backward-compatible String adapter retained for unit tests and embedders.
# Deferred tool results are cancelled here, exactly like the registry's
# synchronous seam, so callers of this adapter never block.
func handle_message(text: String) -> String:
	var out = handle_request(text)
	if out is ToolRegistry.Deferred:
		out.cancel("This tool requires deferred transport dispatch")
		out = out.value
	return out["body"]

# Body-only asynchronous adapter: a serialized String, or a Deferred that
# resolves to one once a runtime operation completes.
func handle_message_async(text: String) -> Variant:
	var out = handle_request(text)
	if out is ToolRegistry.Deferred:
		return out.transform(func(response): return response["body"])
	return out["body"]

# Structured transport seam. Returns {status, body, content_type}, or a
# Deferred that resolves to that shape. HTTP context is intentionally
# request-local; no negotiated version or client metadata is stored on the
# handler.
func handle_request(text: String, http_context := {}) -> Variant:
	var req := JsonRpc.parse(text)
	if not req["ok"]:
		# JSON-RPC 2.0 requires `id` on every error and uses null when the request
		# cannot be identified. The modern schema makes `id` optional, so a request
		# that announced a modern version omits it instead of sending null.
		var include_id: bool = req["has_error_id"] or not _is_modern_context(http_context)
		return _transport_response(400, JsonRpc.error(req["id"], req["error_code"], req["error_message"], null, include_id))
	if req["message_type"] == "response":
		return _transport_response(400, JsonRpc.error(req["id"], -32600, "Invalid Request: client responses are not accepted"))
	if req["is_notification"] and req["method"] != "notifications/initialized":
		return _accepted()
	var protocol := _select_protocol(req, http_context)
	if not protocol["ok"]:
		return _transport_response(protocol.get("status", 400), JsonRpc.error(
			req["id"], protocol["code"], protocol["message"], protocol.get("data")))
	if protocol["modern"] and not http_context.is_empty():
		var header_check := _validate_modern_headers(req, protocol, http_context)
		if not header_check["ok"]:
			return _transport_response(400, JsonRpc.error(req["id"], -32020, header_check["message"]))
	var resp = _handle(req, protocol)
	if resp == null:
		return _accepted()
	if resp is ToolRegistry.Deferred:
		return resp.transform(func(envelope): return _transport_response(_status_for(protocol, envelope), envelope))
	return _transport_response(_status_for(protocol, resp), resp)

# Modern requests map an unknown RPC method to HTTP 404; everything else is 200.
func _status_for(protocol: Dictionary, envelope: Dictionary) -> int:
	if protocol["modern"] and envelope.has("error") and envelope["error"]["code"] == -32601:
		return 404
	return 200

func _accepted() -> Dictionary:
	return {"status": 202, "body": "", "content_type": "application/json"}

func _transport_response(status: int, envelope: Dictionary) -> Dictionary:
	return {"status": status, "body": JSON.stringify(envelope), "content_type": "application/json"}

func _is_modern_context(http_context: Dictionary) -> bool:
	return http_context.get("headers", {}).get("mcp-protocol-version", "") == MODERN_PROTOCOL_VERSION

# A request is modern only when its metadata carries the reserved protocol
# version key. Legacy requests may legitimately send `_meta` (for example a
# `progressToken`), so the mere presence of `_meta` must not select the
# modern path.
func _select_protocol(req: Dictionary, http_context := {}) -> Dictionary:
	if req["is_notification"]:
		return {"ok": true, "modern": false, "version": LEGACY_PROTOCOL_VERSION}
	var params: Dictionary = req["params"]
	if params.has("_meta") and typeof(params["_meta"]) != TYPE_DICTIONARY:
		return {"ok": false, "code": -32602, "message": "Invalid params: _meta must be an object"}
	var meta: Dictionary = params.get("_meta", {})
	if not meta.has(META_PROTOCOL_VERSION):
		if req["method"] == "server/discover" or (_modern_enabled and _is_modern_context(http_context)):
			return {"ok": false, "code": -32602, "message": "Invalid params: modern request metadata is required"}
		# A legacy-shaped body may only run under the legacy revision (or no
		# header at all, for clients that predate it). Any other announced
		# version is rejected instead of silently downgraded.
		var header_version: String = http_context.get("headers", {}).get("mcp-protocol-version", "")
		if header_version != "" and header_version != LEGACY_PROTOCOL_VERSION:
			return _unsupported_version(header_version)
		return {"ok": true, "modern": false, "version": LEGACY_PROTOCOL_VERSION}
	if typeof(meta[META_PROTOCOL_VERSION]) != TYPE_STRING:
		return {"ok": false, "code": -32602, "message": "Invalid params: modern protocolVersion metadata must be a string"}
	if not meta.has(META_CLIENT_CAPABILITIES) or typeof(meta[META_CLIENT_CAPABILITIES]) != TYPE_DICTIONARY:
		return {"ok": false, "code": -32602, "message": "Invalid params: modern clientCapabilities metadata is required"}
	if meta.has(META_CLIENT_INFO):
		var client_info = meta[META_CLIENT_INFO]
		if typeof(client_info) != TYPE_DICTIONARY or typeof(client_info.get("name")) != TYPE_STRING or typeof(client_info.get("version")) != TYPE_STRING:
			return {"ok": false, "code": -32602, "message": "Invalid params: clientInfo requires string name and version"}
	var requested: String = meta[META_PROTOCOL_VERSION]
	if requested != MODERN_PROTOCOL_VERSION or not _modern_enabled:
		return _unsupported_version(requested)
	return {"ok": true, "modern": true, "version": requested, "client_capabilities": meta[META_CLIENT_CAPABILITIES]}

func _unsupported_version(requested: String) -> Dictionary:
	return {
		"ok": false, "status": 400, "code": -32022,
		"message": "Unsupported protocol version: " + requested,
		"data": {"supported": _supported_versions(), "requested": requested},
	}

func _supported_versions() -> Array:
	var versions := [LEGACY_PROTOCOL_VERSION]
	if _modern_enabled:
		versions.append(MODERN_PROTOCOL_VERSION)
	return versions

func _validate_modern_headers(req: Dictionary, protocol: Dictionary, http_context: Dictionary) -> Dictionary:
	var headers: Dictionary = http_context.get("headers", {})
	var values: Dictionary = http_context.get("header_values", {})
	for required in ["mcp-protocol-version", "mcp-method"]:
		if not values.has(required) or values[required].size() != 1:
			return {"ok": false, "message": "Header mismatch: %s must appear exactly once" % required}
	if headers.get("mcp-protocol-version", "") != protocol["version"]:
		return {"ok": false, "message": "Header mismatch: MCP-Protocol-Version must match request metadata"}
	if headers.get("mcp-method", "") != req["method"]:
		return {"ok": false, "message": "Header mismatch: Mcp-Method must match request method"}
	var expected_name = null
	var needs_name: bool = req["method"] in ["tools/call", "resources/read"]
	if req["method"] == "tools/call":
		expected_name = req["params"].get("name")
	elif req["method"] == "resources/read":
		expected_name = req["params"].get("uri")
	if needs_name:
		if typeof(expected_name) != TYPE_STRING or not values.has("mcp-name") or values["mcp-name"].size() != 1:
			return {"ok": false, "message": "Header mismatch: Mcp-Name is required"}
		var decoded := _decode_header_value(headers["mcp-name"])
		if not decoded["ok"] or decoded["value"] != expected_name:
			return {"ok": false, "message": "Header mismatch: Mcp-Name does not match request params"}
	return {"ok": true}

# Plain values must be visible ASCII; anything else (and any value that itself
# matches the sentinel pattern) arrives Base64-encoded as =?base64?...?= and
# must round-trip losslessly.
func _decode_header_value(value: String) -> Dictionary:
	if value.begins_with("=?base64?") and value.ends_with("?=") and value.length() >= 11:
		var encoded := value.substr(9, value.length() - 11)
		if encoded.is_empty():
			return {"ok": false}
		var base64_pattern := RegEx.new()
		base64_pattern.compile("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")
		if base64_pattern.search(encoded) == null:
			return {"ok": false}
		var raw := Marshalls.base64_to_raw(encoded)
		if Marshalls.raw_to_base64(raw) != encoded:
			return {"ok": false}
		var decoded := raw.get_string_from_utf8()
		if decoded.to_utf8_buffer() != raw:
			return {"ok": false}
		return {"ok": true, "value": decoded}
	# to_ascii_buffer() silently replaces non-ASCII code points, so inspect
	# the actual code points instead.
	for i in range(value.length()):
		var code := value.unicode_at(i)
		if code < 32 or code > 126:
			return {"ok": false}
	return {"ok": true, "value": value}

func _server_capabilities() -> Dictionary:
	return {"tools": {}, "resources": {}}

func _server_metadata() -> Dictionary:
	return {"io.modelcontextprotocol/serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}}

func _handle(req: Dictionary, protocol := {"modern": false}):
	var method: String = req["method"]
	var id = req["id"]
	if protocol["modern"]:
		if method == "server/discover":
			return JsonRpc.result(id, {
				"supportedVersions": _supported_versions(),
				"capabilities": _server_capabilities(),
				"resultType": "complete",
				"ttlMs": 0,
				"cacheScope": "private",
				"_meta": _server_metadata(),
			})
		# Handshake and ping were removed in 2026-07-28; they never reach the
		# legacy dispatch path from a modern request.
		if method in ["initialize", "notifications/initialized", "ping"]:
			return JsonRpc.error(id, -32601, "Method not found: " + method)
	var response = _dispatch_method(req)
	if not protocol["modern"] or response == null:
		return response
	if response is ToolRegistry.Deferred:
		# Runtime tools resolve later; decorate the envelope when it completes.
		return response.transform(func(envelope): return _decorate_modern_envelope(envelope, method))
	return _decorate_modern_envelope(response, method)

func _decorate_modern_envelope(envelope: Dictionary, method: String) -> Dictionary:
	if envelope.has("result"):
		envelope["result"] = _decorate_modern_result(envelope["result"], method)
	return envelope

func _decorate_modern_result(value, method: String) -> Dictionary:
	var result: Dictionary = value.duplicate(true) if typeof(value) == TYPE_DICTIONARY else {"value": value}
	result["resultType"] = "complete"
	var metadata: Dictionary = result.get("_meta", {}).duplicate(true)
	metadata.merge(_server_metadata(), true)
	result["_meta"] = metadata
	if method in ["server/discover", "tools/list", "resources/list", "resources/read", "resources/templates/list"]:
		result["ttlMs"] = 0
		result["cacheScope"] = "private"
	return result

func _dispatch_method(req: Dictionary):
	var method: String = req["method"]
	var id = req["id"]
	match method:
		"initialize":
			return JsonRpc.result(id, {
				"protocolVersion": LEGACY_PROTOCOL_VERSION,
				"capabilities": _server_capabilities(),
				"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
			})
		"notifications/initialized":
			return null
		"ping":
			return JsonRpc.result(id, {})
		"tools/list":
			return JsonRpc.result(id, {"tools": _registry.list_tools()})
		"tools/call":
			var p: Dictionary = req["params"]
			var name = p.get("name")
			var args = p.get("arguments", {})
			if typeof(name) != TYPE_STRING or typeof(args) != TYPE_DICTIONARY:
				return JsonRpc.error(id, -32602, "Invalid params: tools/call requires a string name and object arguments")
			var result = _registry.call_tool_async(name, args)
			if result is ToolRegistry.Deferred:
				return result.transform(func(value): return JsonRpc.result(id, value))
			return JsonRpc.result(id, result)
		"resources/list":
			return JsonRpc.result(id, {"resources": _resources.list_resources()})
		"resources/templates/list":
			return JsonRpc.result(id, {"resourceTemplates": []})
		"resources/read":
			var rp: Dictionary = req["params"]
			var uri := str(rp.get("uri", ""))
			if not _resources.has(uri):
				return JsonRpc.error(id, -32602, "Unknown resource: " + uri)
			return JsonRpc.result(id, _resources.read_resource(uri))
		_:
			if req["is_notification"]:
				return null
			return JsonRpc.error(id, -32601, "Method not found: " + method)

func _build_default_registry(project = null, scene = null):
	var reg = ToolRegistry.new()
	var build_tools = BuildTools.new()
	build_tools.register_tools(reg)
	reg.set_meta("_build", build_tools)
	var scenario_tools = ScenarioTools.new()
	scenario_tools.register_tools(reg)
	reg.set_meta("_scenario_tools", scenario_tools)
	var runtime_tools = RuntimeTools.new()
	runtime_tools.register_tools(reg)
	reg.set_meta("_runtime_tools", runtime_tools)
	var files = FileTools.new()
	var scripts = ScriptTools.new()
	reg.register("read_file", "Read a UTF-8 text file from the project. Args: {path}.",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(files, "read_file"))
	reg.register("list_dir", "List entries of a project directory. Args: {path}.",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(files, "list_dir"))
	reg.register("search_project", "Search project files for a substring. Args: {query, path?}.",
		{"type": "object", "properties": {"query": {"type": "string"}, "path": {"type": "string"}}, "required": ["query"]},
		Callable(files, "search_project"))
	reg.register("create_script", "Create a new .gd script (makes parent dirs). Args: {path, content}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
		Callable(scripts, "create_script"))
	reg.register("edit_script", "Edit an existing script. Either overwrite with {content}, or find/replace with {find, replace?, replace_all?}. Args: {path, content?, find?, replace?, replace_all?}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}, "find": {"type": "string"}, "replace": {"type": "string"}, "replace_all": {"type": "boolean"}}, "required": ["path"]},
		Callable(scripts, "edit_script"))
	reg.register("list_scripts", "Recursively list .gd scripts under a path with their class_name/extends. Args: {path?} (default res://).",
		{"type": "object", "properties": {"path": {"type": "string"}}},
		Callable(scripts, "list_scripts"))
	reg.register("get_open_scripts", "List scripts open in the editor and the current one (empty headlessly). No args.",
		{"type": "object", "properties": {}},
		Callable(scripts, "get_open_scripts"))
	reg.register("validate_script", "Validate GDScript syntax. Args: {content} or {path}.",
		{"type": "object", "properties": {"content": {"type": "string"}, "path": {"type": "string"}}},
		Callable(scripts, "validate_script"))
	if project == null:
		project = ProjectTools.new()
	reg.register("get_project_settings", "Get author-set project settings. Args: {key?, prefix?}.",
		{"type": "object", "properties": {"key": {"type": "string"}, "prefix": {"type": "string"}}},
		Callable(project, "get_project_settings"))
	reg.register("list_project_resources", "List Godot resource files (.tres/.res/.tscn). Args: {path?}.",
		{"type": "object", "properties": {"path": {"type": "string"}}},
		Callable(project, "list_project_resources"))
	reg.register("get_project_info", "Get curated project metadata (name, version, autoloads, ...). No args.",
		{"type": "object", "properties": {}},
		Callable(project, "get_project_info"))
	if scene == null:
		scene = SceneTools.new()
	reg.register("get_scene_tree", "Get the current edited scene's node tree. No args.",
		{"type": "object", "properties": {}},
		Callable(scene, "get_scene_tree"))
	reg.register("get_node_properties", "Get a node's properties. Args: {path} (NodePath relative to scene root; '.' = root).",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(scene, "get_node_properties"))
	reg.register("create_node", "Create a node under a parent. Args: {parent_path, type, name?, properties?} (properties values are Godot var_to_str strings).",
		{"type": "object", "properties": {"parent_path": {"type": "string"}, "type": {"type": "string"}, "name": {"type": "string"}, "properties": {"type": "object"}}, "required": ["parent_path", "type"]},
		Callable(scene, "create_node"))
	reg.register("delete_node", "Delete a node. Args: {path}.",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(scene, "delete_node"))
	reg.register("modify_node", "Set node properties (values are Godot var_to_str strings). Args: {path, properties}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "properties": {"type": "object"}}, "required": ["path", "properties"]},
		Callable(scene, "modify_node"))
	reg.register("duplicate_node", "Duplicate a node (and its subtree) under the same parent. Args: {path, new_name?}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "new_name": {"type": "string"}}, "required": ["path"]},
		Callable(scene, "duplicate_node"))
	reg.register("move_node", "Reparent a node under a new parent. Args: {path, new_parent_path, keep_global_transform?}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "new_parent_path": {"type": "string"}, "keep_global_transform": {"type": "boolean"}}, "required": ["path", "new_parent_path"]},
		Callable(scene, "move_node"))
	reg.register("rename_node", "Rename a node. Args: {path, name}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "name": {"type": "string"}}, "required": ["path", "name"]},
		Callable(scene, "rename_node"))
	reg.register("get_signals", "List a node's signals and their current connections. Args: {path}.",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(scene, "get_signals"))
	reg.register("connect_signal", "Connect a node signal to a method on another node (persistent by default). Args: {from_path, signal, to_path, method, flags?}.",
		{"type": "object", "properties": {"from_path": {"type": "string"}, "signal": {"type": "string"}, "to_path": {"type": "string"}, "method": {"type": "string"}, "flags": {"type": "integer"}}, "required": ["from_path", "signal", "to_path", "method"]},
		Callable(scene, "connect_signal"))
	reg.register("disconnect_signal", "Disconnect a node signal from a method on another node. Args: {from_path, signal, to_path, method}.",
		{"type": "object", "properties": {"from_path": {"type": "string"}, "signal": {"type": "string"}, "to_path": {"type": "string"}, "method": {"type": "string"}}, "required": ["from_path", "signal", "to_path", "method"]},
		Callable(scene, "disconnect_signal"))
	reg.register("get_node_groups", "Get the groups a node belongs to. Args: {path}.",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(scene, "get_node_groups"))
	reg.register("set_node_groups", "Set a node's groups (persistent), diffing against current membership. Args: {path, groups}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "groups": {"type": "array", "items": {"type": "string"}}}, "required": ["path", "groups"]},
		Callable(scene, "set_node_groups"))
	reg.register("find_nodes_in_group", "Find paths of nodes in a group within the edited scene. Args: {group}.",
		{"type": "object", "properties": {"group": {"type": "string"}}, "required": ["group"]},
		Callable(scene, "find_nodes_in_group"))
	reg.register("add_resource", "Instantiate a Resource and assign it to a node property. Args: {path, property, type, sub_properties?} (sub_properties values are Godot var_to_str strings).",
		{"type": "object", "properties": {"path": {"type": "string"}, "property": {"type": "string"}, "type": {"type": "string"}, "sub_properties": {"type": "object"}}, "required": ["path", "property", "type"]},
		Callable(scene, "add_resource"))
	reg.register("set_anchor_preset", "Apply a Control anchor preset. Args: {path, preset (int or name like 'full_rect'), keep_offsets?}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "preset": {"type": ["integer", "string"]}, "keep_offsets": {"type": "boolean"}}, "required": ["path", "preset"]},
		Callable(scene, "set_anchor_preset"))
	reg.register("attach_script", "Attach an existing .gd script to a node. Args: {path, script_path}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "script_path": {"type": "string"}}, "required": ["path", "script_path"]},
		Callable(scene, "attach_script"))
	reg.register("create_scene", "Create a new .tscn scene file with a single root node. Args: {path, root_type, root_name?, overwrite?}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "root_type": {"type": "string"}, "root_name": {"type": "string"}, "overwrite": {"type": "boolean"}}, "required": ["path", "root_type"]},
		Callable(scene, "create_scene"))
	reg.register("save_scene", "Save the currently open scene. Without {path}: saves in-place via the editor. With {path} (.tscn): packs a variant copy without touching the live scene; refuses to clobber an existing file unless overwrite=true. Args: {path?, overwrite?}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "overwrite": {"type": "boolean"}}},
		Callable(scene, "save_scene"))
	reg.register("capture_texture", "Read back a texture from the edited scene as PNG: a SubViewport's render target (omit property) or any Texture2D property. Args: {path, property?, out_path?} (PNG to res:// path, else base64).",
		{"type": "object", "properties": {"path": {"type": "string"}, "property": {"type": "string"}, "out_path": {"type": "string"}}, "required": ["path"]},
		Callable(scene, "capture_texture"))
	var editor = EditorTools.new()
	reg.register("get_output_log", "Get captured editor log entries. Args: {limit?, errors_only?}.",
		{"type": "object", "properties": {"limit": {"type": "integer"}, "errors_only": {"type": "boolean"}}},
		Callable(editor, "get_output_log"))
	reg.register("clear_output", "Clear the MCP capture buffer (NOT the editor's Output dock). No args.",
		{"type": "object", "properties": {}},
		Callable(editor, "clear_output"))
	reg.register("get_editor_errors", "Get captured editor errors/warnings only. Args: {limit?}.",
		{"type": "object", "properties": {"limit": {"type": "integer"}}},
		Callable(editor, "get_editor_errors"))
	reg.register("get_editor_screenshot", "Screenshot the editor window (windowed editor only). Args: {path?} (PNG to res:// path, else base64). ",
		{"type": "object", "properties": {"path": {"type": "string"}}},
		Callable(editor, "get_editor_screenshot"))
	reg.register("reload_project", "Trigger an editor filesystem rescan. No args.",
		{"type": "object", "properties": {}},
		Callable(editor, "reload_project"))
	var input = InputTools.new()
	reg.register("get_input_actions", "Get the project input map actions (input/* in ProjectSettings). No args.",
		{"type": "object", "properties": {}},
		Callable(input, "get_input_actions"))
	reg.register("set_input_action", "Create/update an input map action (partial update). Args: {name, events? (Array of var_to_str InputEvent strings), deadzone?}.",
		{"type": "object", "properties": {"name": {"type": "string"}, "events": {"type": "array", "items": {"type": "string"}}, "deadzone": {"type": "number"}}, "required": ["name"]},
		Callable(input, "set_input_action"))
	var uids = UidTools.new()
	reg.register("get_uid", "Get the UID of a resource file. Args: {path}.",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(uids, "get_uid"))
	reg.register("update_project_uids", "Resave .tscn/.tres/.res files to regenerate UID sidecars. Args: {path?} (default res://).",
		{"type": "object", "properties": {"path": {"type": "string"}}},
		Callable(uids, "update_project_uids"))
	reg.set_meta("_scene", scene)
	reg.set_meta("_project", project)
	# Keep tool instances alive for the lifetime of the registry by stashing them.
	reg.set_meta("_files", files)
	reg.set_meta("_scripts", scripts)
	reg.set_meta("_editor", editor)
	reg.set_meta("_input", input)
	reg.set_meta("_uids", uids)
	return reg

func _build_default_resource_registry(project = null, scene = null):
	var rreg = ResourceRegistry.new()
	if project == null:
		project = ProjectTools.new()
	rreg.register("godot://project/info", "project_info",
		"Project metadata and settings.", "application/json",
		Callable(project, "get_project_info"))
	if scene == null:
		scene = SceneTools.new()
	rreg.register("godot://scene/current", "scene_current",
		"The currently open scene (path + node tree).", "application/json",
		Callable(scene, "scene_current"))
	rreg.register("godot://script/current", "script_current",
		"The currently open script (path + source).", "application/json",
		Callable(scene, "script_current"))
	rreg.set_meta("_scene", scene)
	rreg.set_meta("_project", project)
	return rreg
