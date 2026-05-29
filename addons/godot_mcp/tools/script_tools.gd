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
	gd.source_code = src
	var err := gd.reload()
	OS.remove_logger(cap)
	return {"ok": true, "value": {"valid": err == OK, "errors": cap.errors}}

# Only meaningful inside a live editor; the plugin registers itself in Engine metadata (Task 10).
func _rescan_filesystem() -> void:
	if not Engine.has_meta("GodotMCPPlugin"):
		return
	var plugin = Engine.get_meta("GodotMCPPlugin")
	var ei = plugin.get_editor_interface()
	ei.get_resource_filesystem().scan()
