@tool
extends RefCounted
static func clean_log(text: String) -> String:
	var ansi := RegEx.new()
	ansi.compile("\\x1b\\[[0-?]*[ -/]*[@-~]")
	var plain := ansi.sub(text, "", true)
	var controls := RegEx.new()
	controls.compile("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f]")
	return controls.sub(plain, "", true)

static func clean_value(value: Variant, depth: int = 0) -> Variant:
	if depth > 16:
		return "[truncated]"
	if value is String:
		return clean_log(value)
	if value is Array:
		var out := []
		for child in value:
			out.append(clean_value(child, depth + 1))
		return out
	if value is Dictionary:
		var out := {}
		for key in value:
			out[clean_log(str(key))] = clean_value(value[key], depth + 1)
		return out
	return value
