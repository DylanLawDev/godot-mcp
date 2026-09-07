@tool
extends RefCounted

# Parse a single JSON-RPC 2.0 message. Returns
# {ok, id, method, params, is_notification}. A request without "id" is a notification.
static func parse(text: String) -> Dictionary:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "id": null, "method": "", "params": {}, "is_notification": false}
	var id = data.get("id", null)
	# Godot parses JSON numbers as floats. Restore integral IDs so strict MCP
	# clients receive e.g. 1, not 1.0, in both success and error responses.
	# Only convert within the exact integer range of a JSON-parsed double.
	if typeof(id) == TYPE_FLOAT and abs(id) <= 9007199254740991.0 and id == floor(id):
		id = int(id)
	var has_id: bool = data.has("id")
	var params = data.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}
	return {
		"ok": true,
		"id": id,
		"method": data.get("method", ""),
		"params": params,
		"is_notification": not has_id,
	}

static func result(id, result_value) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result_value}

static func error(id, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
