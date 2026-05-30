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
const ResourceRegistry = preload("res://addons/godot_mcp/resource_registry.gd")

const PROTOCOL_VERSION := "2025-06-18"
const SERVER_NAME := "godot-mcp"
const SERVER_VERSION := "0.1.0"

var _registry
var _resources

func _init(registry = null, resources = null) -> void:
	var project = ProjectTools.new()
	var scene = SceneTools.new()
	_registry = registry if registry != null else _build_default_registry(project, scene)
	_resources = resources if resources != null else _build_default_resource_registry(project, scene)

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
				"capabilities": {"tools": {}, "resources": {}},
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
		"resources/list":
			return JsonRpc.result(id, {"resources": _resources.list_resources()})
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
	reg.set_meta("_scene", scene)
	reg.set_meta("_project", project)
	# Keep tool instances alive for the lifetime of the registry by stashing them.
	reg.set_meta("_files", files)
	reg.set_meta("_scripts", scripts)
	reg.set_meta("_editor", editor)
	reg.set_meta("_input", input)
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
