@tool
extends RefCounted

var _resources: Array = []  # each: {uri, name, description, mimeType, handler: Callable}

func register(uri: String, name: String, description: String, mime_type: String, handler: Callable) -> void:
	_resources.append({
		"uri": uri,
		"name": name,
		"description": description,
		"mimeType": mime_type,
		"handler": handler,
	})

# Descriptors only — the shape MCP resources/list expects.
func list_resources() -> Array:
	var out := []
	for r in _resources:
		out.append({
			"uri": r["uri"],
			"name": r["name"],
			"description": r["description"],
			"mimeType": r["mimeType"],
		})
	return out

func has(uri: String) -> bool:
	for r in _resources:
		if r["uri"] == uri:
			return true
	return false

# Returns the MCP resources/read result: {contents: [{uri, mimeType, text}]}.
func read_resource(uri: String) -> Dictionary:
	for r in _resources:
		if r["uri"] == uri:
			var res: Dictionary = r["handler"].call({})
			var text: String
			if res.get("ok", false):
				var val = res.get("value")
				text = val if typeof(val) == TYPE_STRING else JSON.stringify(val)
			else:
				text = str(res.get("error", "unknown error"))
			return {"contents": [{"uri": uri, "mimeType": r["mimeType"], "text": text}]}
	return {"contents": []}
