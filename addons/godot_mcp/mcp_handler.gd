@tool
extends RefCounted

const JsonRpc = preload("res://addons/godot_mcp/jsonrpc.gd")
const ToolRegistry = preload("res://addons/godot_mcp/tool_registry.gd")
const FileTools = preload("res://addons/godot_mcp/tools/file_tools.gd")
const ScriptTools = preload("res://addons/godot_mcp/tools/script_tools.gd")

const PROTOCOL_VERSION := "2025-06-18"
const SERVER_NAME := "godot-mcp"
const SERVER_VERSION := "0.1.0"

var _registry

func _init(registry = null) -> void:
	_registry = registry if registry != null else _build_default_registry()

# Single seam for the HTTP server AND tests.
# Returns the serialized JSON-RPC response, or "" for notifications (server replies 202, no body).
func handle_message(text: String) -> String:
	var req := JsonRpc.parse(text)
	if not req["ok"]:
		return JSON.stringify(JsonRpc.error(null, -32700, "Parse error"))
	var resp = _handle(req)
	if resp == null:
		return ""
	return JSON.stringify(resp)

func _handle(req: Dictionary):
	var method: String = req["method"]
	var id = req["id"]
	match method:
		"initialize":
			var pv = req["params"].get("protocolVersion", PROTOCOL_VERSION)
			if typeof(pv) != TYPE_STRING:
				pv = PROTOCOL_VERSION
			return JsonRpc.result(id, {
				"protocolVersion": pv,
				"capabilities": {"tools": {}},
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
			return JsonRpc.result(id, _registry.call_tool(str(p.get("name", "")), p.get("arguments", {})))
		_:
			if req["is_notification"]:
				return null
			return JsonRpc.error(id, -32601, "Method not found: " + method)

func _build_default_registry():
	var reg = ToolRegistry.new()
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
	reg.register("edit_script", "Overwrite an existing script's contents. Args: {path, content}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
		Callable(scripts, "edit_script"))
	reg.register("validate_script", "Validate GDScript syntax. Args: {content} or {path}.",
		{"type": "object", "properties": {"content": {"type": "string"}, "path": {"type": "string"}}},
		Callable(scripts, "validate_script"))
	# Keep tool instances alive for the lifetime of the registry by stashing them.
	reg.set_meta("_files", files)
	reg.set_meta("_scripts", scripts)
	return reg
