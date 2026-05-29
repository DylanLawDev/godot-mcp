@tool
extends RefCounted

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

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
	var settings := _author_settings()
	if settings.is_empty():
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
			if str(k).begins_with(prefix):
				filtered[k] = settings[k]
		return {"ok": true, "value": filtered}
	return {"ok": true, "value": settings}

# Author-set settings = exactly what's written in project.godot (no engine defaults).
func _author_settings() -> Dictionary:
	var out := {}
	var cfg := ConfigFile.new()
	if cfg.load("res://project.godot") != OK:
		return out
	for section in cfg.get_sections():
		for k in cfg.get_section_keys(section):
			var full_key := (section + "/" + k) if section != "" else k
			out[full_key] = cfg.get_value(section, k)
	return out
