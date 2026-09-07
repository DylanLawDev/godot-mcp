@tool
extends RefCounted

# Parse and validate one JSON-RPC 2.0 message. Parsing is deliberately kept
# separate from dispatch so malformed values are never read through typed
# GDScript variables.
static func parse(text: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return _invalid(-32700, "Parse error", false)
	var data = parser.data
	if typeof(data) != TYPE_DICTIONARY:
		return _invalid(-32600, "Invalid Request", false)
	if data.get("jsonrpc") != "2.0":
		return _invalid(-32600, "Invalid Request: jsonrpc must be \"2.0\"", false)

	# A client response is a valid JSON-RPC message, but it is not a message this
	# request/response-only server accepts on its HTTP endpoint.
	if not data.has("method"):
		if data.has("id") and _valid_id(data["id"]) and (data.has("result") != data.has("error")):
			return {
				"ok": true, "message_type": "response", "id": _normalize_id(data["id"]),
				"method": "", "params": {}, "is_notification": false,
			}
		return _invalid(-32600, "Invalid Request: method is required", false)
	if typeof(data["method"]) != TYPE_STRING:
		var identified: bool = data.has("id") and _valid_id(data["id"])
		return _invalid(-32600, "Invalid Request: method must be a string", identified, data.get("id") if identified else null)

	var has_id: bool = data.has("id")
	if has_id and not _valid_id(data["id"]):
		return _invalid(-32600, "Invalid Request: id must be a string or number", false)
	var id = data.get("id", null)
	id = _normalize_id(id)
	var params = data.get("params", {})
	if data.has("params") and typeof(params) != TYPE_DICTIONARY:
		return _invalid(-32602, "Invalid params: expected an object", has_id, id)
	return {
		"ok": true,
		"message_type": "notification" if not has_id else "request",
		"id": id,
		"method": data["method"],
		"params": params,
		"is_notification": not has_id,
	}

static func _valid_id(value) -> bool:
	return typeof(value) in [TYPE_STRING, TYPE_INT, TYPE_FLOAT]

static func _normalize_id(value):
	# Godot parses JSON numbers as floats. Restore integral IDs so strict MCP
	# clients receive e.g. 1, not 1.0, in both success and error responses.
	if typeof(value) == TYPE_FLOAT and abs(value) <= 9007199254740991.0 and value == floor(value):
		return int(value)
	return value

static func _invalid(code: int, message: String, identified: bool, id = null) -> Dictionary:
	return {
		"ok": false, "error_code": code, "error_message": message,
		"has_error_id": identified, "id": _normalize_id(id), "method": "",
		"params": {}, "message_type": "invalid", "is_notification": false,
	}

static func result(id, result_value) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result_value}

static func error(id, code: int, message: String, data = null, include_id := true) -> Dictionary:
	var envelope := {"jsonrpc": "2.0", "error": {"code": code, "message": message}}
	if include_id:
		envelope["id"] = id
	if data != null:
		envelope["error"]["data"] = data
	return envelope
