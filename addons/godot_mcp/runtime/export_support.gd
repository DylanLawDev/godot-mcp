@tool
extends RefCounted
const PLATFORMS := ["Linux", "Windows Desktop", "macOS"]
static func prepare(preset: String, mode: String, source: String) -> Dictionary:
	var config := ConfigFile.new()
	if config.load(source.path_join("export_presets.cfg")) != OK:
		return {"ok": false, "error": "No readable export_presets.cfg; create a desktop preset in Godot first"}
	var section := ""
	for candidate in config.get_sections():
		if candidate.begins_with("preset.") and not candidate.ends_with(".options") and config.get_value(candidate, "name", "") == preset:
			if section != "":
				return {"ok": false, "error": "Export preset name is ambiguous"}
			section = candidate
	if section == "":
		return {"ok": false, "error": "Unknown export preset: " + preset}
	var platform: String = str(config.get_value(section, "platform", ""))
	if platform not in PLATFORMS:
		return {"ok": false, "error": "Only Linux, Windows Desktop and macOS export presets are supported"}
	var options := section + ".options"
	var architecture: String = str(config.get_value(options, "binary_format/architecture", "x86_64"))
	var template: String = str(config.get_value(options, "custom_template/" + mode, ""))
	if template != "":
		template = template.replace("res://", source + "/") if template.begins_with("res://") else (template if template.is_absolute_path() else source.path_join(template))
	else:
		var version := Engine.get_version_info()
		var folder := "%s.%s.%s.%s" % [version.major, version.minor, version.patch, version.status]
		var name := "macos.zip"
		if platform == "Linux":
			name = "linux_%s.%s" % [mode, architecture]
		elif platform == "Windows Desktop":
			name = "windows_%s_%s.exe" % [mode, architecture]
		var data_dir: String = EditorInterface.get_editor_paths().get_data_dir() if Engine.is_editor_hint() else OS.get_data_dir().path_join("Godot" if OS.get_name() in ["Windows", "macOS"] else "godot")
		template = data_dir.path_join("export_templates").path_join(folder).path_join(name)
	if not FileAccess.file_exists(template):
		return {"ok": false, "error": "Required export template is missing for " + platform + " (" + mode + "). Install matching Godot templates or configure a custom template in the preset."}
	var filename := "game.zip" if platform == "macOS" else ("game.exe" if platform == "Windows Desktop" else "game." + architecture)
	# Filename must remain a single path component even with a malformed preset.
	if "/" in filename or "\\" in filename or ".." in filename:
		return {"ok": false, "error": "Invalid preset architecture"}
	var redactions := []
	for key in config.get_section_keys(options) if config.has_section(options) else []:
		if "password" in key.to_lower() or "secret" in key.to_lower() or "encryption_key" in key.to_lower():
			var value: Variant = config.get_value(options, key)
			if value is String and value != "":
				redactions.append(value)
	return {"ok": true, "value": {"preset": preset, "mode": mode, "platform": platform, "filename": filename, "redactions": redactions}}

static func arguments(snapshot: String, preset: String, mode: String, output: String) -> PackedStringArray:
	return PackedStringArray(["--headless", "--path", snapshot, "--export-" + mode, preset, output])

static func manifest(directory: String, expected: String) -> Dictionary:
	var file := FileAccess.open(expected, FileAccess.READ)
	if file == null or file.get_length() == 0:
		return {"ok": false, "error": "Exporter returned success without the expected nonempty output"}
	var artifacts := []
	var queue: Array[String] = [directory]
	var visited := 0
	while not queue.is_empty():
		var path: String = queue.pop_back()
		var dir := DirAccess.open(path)
		if dir == null:
			return {"ok": false, "error": "Could not inspect exported artifacts"}
		dir.include_hidden = true
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			visited += 1
			if visited > 10000:
				return {"ok": false, "error": "Export artifact manifest exceeds 10000 entries"}
			var child := path.path_join(name)
			if dir.is_link(name):
				return {"ok": false, "error": "Export artifact links are unsupported"}
			if dir.current_is_dir():
				queue.append(child)
			else:
				var artifact := FileAccess.open(child, FileAccess.READ)
				if artifact == null:
					return {"ok": false, "error": "Could not read exported artifact metadata"}
				artifacts.append({"path": child, "size_bytes": artifact.get_length(), "kind": "package" if child == expected else "sidecar"})
			name = dir.get_next()
	return {"ok": true, "value": artifacts}
