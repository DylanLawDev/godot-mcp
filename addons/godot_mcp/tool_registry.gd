@tool
extends RefCounted

var _tools: Array = []  # each: {name, description, inputSchema, handler: Callable}

func register(name: String, description: String, input_schema: Dictionary, handler: Callable) -> void:
	_tools.append({
		"name": name,
		"description": description,
		"inputSchema": input_schema,
		"handler": handler,
	})

# Schemas only — the shape MCP tools/list expects.
func list_tools() -> Array:
	var out := []
	for t in _tools:
		out.append({
			"name": t["name"],
			"description": t["description"],
			"inputSchema": t["inputSchema"],
		})
	return out

# Returns the MCP tools/call result: {content: [{type:"text", text}], isError}.
func call_tool(name: String, args: Dictionary) -> Dictionary:
	for t in _tools:
		if t["name"] == name:
			var r: Dictionary = t["handler"].call(args)
			if r.get("ok", false):
				var val = r.get("value")
				var text: String = val if typeof(val) == TYPE_STRING else JSON.stringify(val)
				return {"content": [{"type": "text", "text": text}], "isError": false}
			return {"content": [{"type": "text", "text": str(r.get("error", "unknown error"))}], "isError": true}
	return {"content": [{"type": "text", "text": "Unknown tool: " + name}], "isError": true}
