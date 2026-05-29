@tool
extends RefCounted

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")
const _RESOURCE_EXTS := ["tres", "res", "tscn"]
const _MAX_RESOURCES := 1000   # cap entries to bound large trees / symlink cycles

func get_project_info(_args: Dictionary) -> Dictionary:
	return {"ok": true, "value": _project_info()}

func _project_info() -> Dictionary:
	var info := {}
	info["name"] = str(ProjectSettings.get_setting("application/config/name", ""))
	var desc := str(ProjectSettings.get_setting("application/config/description", ""))
	if desc != "":
		info["description"] = desc
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	if ver != "":
		info["version"] = ver
	var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene != "":
		info["main_scene"] = main_scene
	var icon := str(ProjectSettings.get_setting("application/config/icon", ""))
	if icon != "":
		info["icon"] = icon
	info["features"] = Array(ProjectSettings.get_setting("application/config/features", PackedStringArray()))
	info["godot_version"] = Engine.get_version_info().get("string", "")
	info["autoloads"] = _autoloads()
	return info

func _autoloads() -> Array:
	var out := []
	var cfg := ConfigFile.new()
	if cfg.load("res://project.godot") != OK:
		return out
	if not cfg.has_section("autoload"):
		return out
	for name in cfg.get_section_keys("autoload"):
		var raw := str(cfg.get_value("autoload", name, ""))
		var singleton := raw.begins_with("*")
		var path := raw.substr(1) if singleton else raw
		out.append({"name": name, "path": path, "singleton": singleton})
	return out

func get_project_settings(args: Dictionary) -> Dictionary:
	var settings = _author_settings()  # null = project.godot failed to load
	if settings == null:
		return {"ok": false, "error": "Cannot load project.godot"}
	var key := str(args.get("key", ""))
	if key != "":
		if not settings.has(key):
			return {"ok": false, "error": "Setting not found: " + key}
		return {"ok": true, "value": {"value": settings[key]}}
	var prefix := str(args.get("prefix", ""))
	if prefix != "":
		var filtered := {}
		for k in settings:
			if k.begins_with(prefix):
				filtered[k] = settings[k]
		return {"ok": true, "value": filtered}
	return {"ok": true, "value": settings}

# Author-set settings = exactly what's written in project.godot (no engine defaults).
# Returns null if the file can't be loaded (distinct from a project with no settings).
func _author_settings() -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load("res://project.godot") != OK:
		return null
	var out := {}
	for section in cfg.get_sections():
		# The "" section holds bare top-level lines like `config_version=5`,
		# which are file-format markers, not project settings — skip them.
		if section == "":
			continue
		for k in cfg.get_section_keys(section):
			out[section + "/" + k] = cfg.get_value(section, k)
	return out

func list_project_resources(args: Dictionary) -> Dictionary:
	var root := str(args.get("path", "res://"))
	var v := Paths.validate(root)
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var entries := []
	_collect_resources(v["path"], entries)
	return {"ok": true, "value": {"entries": entries}}

func _collect_resources(dir_path: String, entries: Array) -> void:
	if entries.size() >= _MAX_RESOURCES:
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var child := dir_path.path_join(name)
		if d.current_is_dir():
			_collect_resources(child, entries)
		elif name.get_extension() in _RESOURCE_EXTS:
			entries.append({"path": child, "type": _resource_type(child)})
		if entries.size() >= _MAX_RESOURCES:
			break
		name = d.get_next()
	d.list_dir_end()

# Determine the resource/root class without load() — parse the text header.
# Reads only a bounded chunk: text resources declare their type in the first line,
# and binary .res files (no text header) must not be read in full.
func _resource_type(path: String) -> String:
	if path.get_extension() == "tscn":
		return "PackedScene"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "Resource"
	var head := f.get_buffer(256).get_string_from_utf8()
	f = null
	var first := head.split("\n")[0]
	# Header looks like: [gd_resource type="Foo" load_steps=.. format=..]
	var marker := 'type="'
	var idx := first.find(marker)
	if idx == -1:
		return "Resource"
	var start := idx + marker.length()
	var end := first.find('"', start)
	if end == -1:
		return "Resource"
	return first.substr(start, end - start)
