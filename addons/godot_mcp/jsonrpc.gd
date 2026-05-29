@tool
extends RefCounted

# Parse a single JSON-RPC 2.0 message. Returns
# {ok, id, method, params, is_notification}. A request without "id" is a notification.
static func parse(text: String) -> Dictionary:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "id": null, "method": "", "params": {}, "is_notification": false}
	var id = data.get("id", null)
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
