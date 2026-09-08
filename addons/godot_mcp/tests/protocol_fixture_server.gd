extends SceneTree

const HttpServer = preload("res://addons/godot_mcp/http_server.gd")
const McpHandler = preload("res://addons/godot_mcp/mcp_handler.gd")

var _server
var _handler
var _deadline_ms := 0

func _initialize() -> void:
	_handler = McpHandler.new()
	_server = HttpServer.new(Callable(_handler, "handle_request"))
	if _server.start(0) != OK:
		printerr("MCP_FIXTURE_ERROR=listen")
		quit(2)
		return
	_deadline_ms = Time.get_ticks_msec() + 30000
	print("MCP_FIXTURE_PORT=%d" % _server.get_port())

func _process(_delta: float) -> bool:
	_server.poll()
	if Time.get_ticks_msec() >= _deadline_ms:
		_server.stop()
		quit(3)
	return false

func _finalize() -> void:
	if _server != null:
		_server.stop()
