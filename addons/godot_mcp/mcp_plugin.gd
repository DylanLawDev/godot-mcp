@tool
extends EditorPlugin

const HttpServer = preload("res://addons/godot_mcp/http_server.gd")
const McpHandler = preload("res://addons/godot_mcp/mcp_handler.gd")
const OutputCapture = preload("res://addons/godot_mcp/tools/output_capture.gd")

const META_KEY := "GodotMCPPlugin"
const CAPTURE_META_KEY := "GodotMCPOutputCapture"
const SETTING_PORT := "godot_mcp/port"
const DEFAULT_PORT := 8765

var _server
var _handler
var _capture

func _enter_tree() -> void:
	Engine.set_meta(META_KEY, self)
	_capture = OutputCapture.new()
	OS.add_logger(_capture)
	Engine.set_meta(CAPTURE_META_KEY, _capture)
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
	if _capture != null:
		OS.remove_logger(_capture)
		_capture = null
	if Engine.has_meta(CAPTURE_META_KEY):
		Engine.remove_meta(CAPTURE_META_KEY)
	if Engine.has_meta(META_KEY):
		Engine.remove_meta(META_KEY)

func _process(_delta: float) -> void:
	if _server != null and _server.is_listening():
		_server.poll()

func _resolve_port() -> int:
	if ProjectSettings.has_setting(SETTING_PORT):
		return int(ProjectSettings.get_setting(SETTING_PORT))
	return DEFAULT_PORT
