@tool
extends EditorPlugin

const HttpServer = preload("res://addons/godot_mcp/http_server.gd")
const McpHandler = preload("res://addons/godot_mcp/mcp_handler.gd")

const META_KEY := "GodotMCPPlugin"
const SETTING_PORT := "godot_mcp/port"
const DEFAULT_PORT := 8765

var _server
var _handler

func _enter_tree() -> void:
	Engine.set_meta(META_KEY, self)
	_handler = McpHandler.new()
	_server = HttpServer.new(Callable(_handler, "handle_message"))
	var port := _resolve_port()
	var err: int = _server.start(port)
	if err == OK:
		set_process(true)
		print("[godot-mcp] MCP HTTP server listening on http://127.0.0.1:%d/mcp" % port)
	else:
		set_process(false)
		printerr("[godot-mcp] Failed to listen on port %d (error %d)" % [port, err])

func _exit_tree() -> void:
	set_process(false)
	if _server != null:
		_server.stop()
	_server = null
	_handler = null
	if Engine.has_meta(META_KEY):
		Engine.remove_meta(META_KEY)

func _process(_delta: float) -> void:
	if _server != null and _server.is_listening():
		_server.poll()

func _resolve_port() -> int:
	if ProjectSettings.has_setting(SETTING_PORT):
		return int(ProjectSettings.get_setting(SETTING_PORT))
	return DEFAULT_PORT
