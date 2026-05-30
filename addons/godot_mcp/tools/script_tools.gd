@tool
extends RefCounted

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

# Captures engine error output (incl. GDScript parse errors) during a reload() window.
class _CaptureLogger extends Logger:
	var errors: Array = []
	func _log_error(_function, _file, line, code, _rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		errors.append({"line": line, "message": code})
	func _log_message(_message, _error) -> void:
		pass

func create_script(args: Dictionary) -> Dictionary:
	var v := Paths.validate(str(args.get("path", "")))
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var path := Paths.ensure_extension(v["path"], ".gd")
	var content := str(args.get("content", ""))
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			return {"ok": false, "error": "Failed to create directory %s (error %d)" % [dir, err]}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Failed to create file: " + path}
	f.store_string(content)
	f = null
	_rescan_filesystem()
	return {"ok": true, "value": {"path": path}}

func edit_script(args: Dictionary) -> Dictionary:
	var v := Paths.validate(str(args.get("path", "")))
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var path: String = v["path"]
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "Script not found: " + path}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Failed to open for writing: " + path}
	f.store_string(str(args.get("content", "")))
	f = null
	_rescan_filesystem()
	return {"ok": true, "value": {"path": path}}

func list_scripts(args: Dictionary) -> Dictionary:
	var raw := str(args.get("path", "res://"))
	if raw == "":
		raw = "res://"
	var v := Paths.validate(raw)
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var root: String = v["path"]
	var out := []
	_walk_scripts(root, out)
	return {"ok": true, "value": {"scripts": out}}

# Recursively collect .gd files under `dir`, appending {path, class_name, extends} for each.
func _walk_scripts(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name == "." or name == "..":
			name = d.get_next()
			continue
		var full := dir.path_join(name)
		if d.current_is_dir():
			_walk_scripts(full, out)
		elif name.ends_with(".gd"):
			var f := FileAccess.open(full, FileAccess.READ)
			var header := {"class_name": "", "extends": ""}
			if f != null:
				header = _parse_script_header(f.get_as_text())
			out.append({"path": full, "class_name": header["class_name"], "extends": header["extends"]})
		name = d.get_next()
	d.list_dir_end()

# Parse a GDScript source's top-level `class_name X` / `extends Y` via per-line prefix
# matching (NOT a compile). Returns {class_name, extends}, each "" when absent.
static func _parse_script_header(text: String) -> Dictionary:
	var out := {"class_name": "", "extends": ""}
	for raw in text.split("\n"):
		var line: String = raw.strip_edges()
		if line.begins_with("class_name "):
			out["class_name"] = line.substr("class_name ".length()).strip_edges()
		elif line.begins_with("extends "):
			out["extends"] = line.substr("extends ".length()).strip_edges()
	return out

func validate_script(args: Dictionary) -> Dictionary:
	var src := str(args.get("content", ""))
	if src == "" and args.has("path"):
		var v := Paths.validate(str(args.get("path", "")))
		if not v["ok"]:
			return {"ok": false, "error": v["error"]}
		if not FileAccess.file_exists(v["path"]):
			return {"ok": false, "error": "Script not found: " + v["path"]}
		src = FileAccess.open(v["path"], FileAccess.READ).get_as_text()
	var cap := _CaptureLogger.new()
	OS.add_logger(cap)
	var gd := GDScript.new()
	# Strip any top-level `class_name` so this detached compile doesn't collide with
	# the same class already registered globally from the on-disk file (which the
	# editor reports as "Class X hides a global script class"). See issue: false
	# negative when validating existing files that declare a class_name.
	gd.source_code = _strip_class_name(src)
	var err := gd.reload()
	OS.remove_logger(cap)
	return {"ok": true, "value": {"valid": err == OK, "errors": cap.errors}}

# Blank out a top-level `class_name X` declaration (preserving line numbers) so it
# is not re-registered during the validation compile. No-op when none is present.
static func _strip_class_name(src: String) -> String:
	var lines := src.split("\n")
	for i in lines.size():
		if lines[i].strip_edges().begins_with("class_name "):
			lines[i] = ""
	return "\n".join(lines)

# Live seam: the script editor inside a running editor, or null headlessly.
func _script_editor():
	if not Engine.has_meta("GodotMCPPlugin"):
		return null
	var plugin = Engine.get_meta("GodotMCPPlugin")
	return plugin.get_editor_interface().get_script_editor()

# Only meaningful inside a live editor; the plugin registers itself in Engine metadata (Task 10).
func _rescan_filesystem() -> void:
	if not Engine.has_meta("GodotMCPPlugin"):
		return
	var plugin = Engine.get_meta("GodotMCPPlugin")
	var ei = plugin.get_editor_interface()
	ei.get_resource_filesystem().scan()
