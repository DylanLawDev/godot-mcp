@tool
extends RefCounted

# Normalize an arbitrary path into a res:// path (no validation).
static func normalize(p: String) -> String:
	if p.begins_with("res://"):
		return p
	while p.begins_with("/"):
		p = p.substr(1)
	return "res://" + p

static func ensure_extension(p: String, ext: String) -> String:
	if p.ends_with(ext):
		return p
	return p + ext

# Normalize AND reject anything that escapes the project root.
# Returns {ok: bool, path: String, error: String}.
static func validate(p: String) -> Dictionary:
	if p.strip_edges() == "":
		return {"ok": false, "path": "", "error": "Path is empty"}
	var norm := normalize(p)
	# Reject parent-directory traversal anywhere in the path.
	var rest := norm.substr("res://".length())
	for segment in rest.split("/"):
		if segment == "..":
			return {"ok": false, "path": "", "error": "Path escapes project root: " + p}
	return {"ok": true, "path": norm, "error": ""}
