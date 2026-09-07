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

const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")

# Legacy synchronous seam; deferred callers use call_tool_async instead.
func call_tool(name: String, args: Dictionary) -> Dictionary:
	var result: Variant = call_tool_async(name, args)
	if result is Deferred:
		result.cancel("This tool requires deferred transport dispatch")
		return result.value
	return result

func call_tool_async(name: String, args: Dictionary) -> Variant:
	for t in _tools:
		if t["name"] == name:
			var result: Variant = t["handler"].call(args)
			if result is Deferred:
				return result.transform(Callable(self, "format_result"))
			return format_result(result)
	return format_result({"ok": false, "error": "Unknown tool: " + name})

static func format_result(result: Variant) -> Dictionary:
	if not result is Dictionary:
		return {"content": [{"type": "text", "text": "Invalid tool result"}], "isError": true}
	if result.get("ok", false):
		var val: Variant = result.get("value")
		var text: String = val if typeof(val) == TYPE_STRING else JSON.stringify(val)
		return {"content": [{"type": "text", "text": text}], "isError": false}
	return {"content": [{"type": "text", "text": str(result.get("error", "unknown error"))}], "isError": true}
