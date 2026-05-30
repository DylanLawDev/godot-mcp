@tool
extends RefCounted

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

func get_uid(args: Dictionary) -> Dictionary:
	var v := Paths.validate(str(args.get("path", "")))
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var path: String = v["path"]
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: " + path}
	var id := ResourceLoader.get_resource_uid(path)
	if id == ResourceUID.INVALID_ID:
		return {"ok": false, "error": "No UID for " + path}
	return {"ok": true, "value": {"path": path, "uid": ResourceUID.id_to_text(id)}}

func update_project_uids(args: Dictionary) -> Dictionary:
	var raw := str(args.get("path", "res://"))
	if raw == "":
		raw = "res://"
	var v := Paths.validate(raw)
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var root: String = v["path"]
	if DirAccess.open(root) == null:
		return {"ok": false, "error": "Directory not found: " + root}
	# Use a counter array [scanned, resaved] so _walk_uids can mutate them by reference.
	var counts := [0, 0]
	var failed: Array = []
	_walk_uids(root, counts, failed)
	_rescan_filesystem()
	return {"ok": true, "value": {"scanned": counts[0], "resaved": counts[1], "failed": failed}}

# Recursively walk `dir` for .tscn/.tres/.res files, reload+resave each.
# Skips symlinked dirs (same as list_scripts/_walk_scripts); DirAccess excludes hidden
# entries by default so no explicit hidden-dir guard is needed.
# counts[0] = scanned, counts[1] = resaved.
func _walk_uids(dir: String, counts: Array, failed: Array) -> void:
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
			# Skip symlinked directories (same convention as list_scripts/_walk_scripts).
			# DirAccess already excludes hidden entries by default.
			if not d.is_link(full):
				_walk_uids(full, counts, failed)
		elif name.ends_with(".tscn") or name.ends_with(".tres") or name.ends_with(".res"):
			counts[0] += 1
			# Load uncached (CACHE_MODE_IGNORE) so a refresh of UID metadata never
			# persists unsaved inspector edits sitting on a cached resource instance.
			var res: Resource = ResourceLoader.load(full, "", ResourceLoader.CACHE_MODE_IGNORE)
			if res == null:
				failed.append({"path": full, "error": "ResourceLoader.load returned null"})
			else:
				var err := ResourceSaver.save(res, full)
				if err != OK:
					failed.append({"path": full, "error": "ResourceSaver.save error %d" % err})
				else:
					counts[1] += 1
		name = d.get_next()
	d.list_dir_end()

# Only meaningful inside a live editor; the plugin registers itself in Engine metadata.
func _rescan_filesystem() -> void:
	if not Engine.has_meta("GodotMCPPlugin"):
		return
	var plugin = Engine.get_meta("GodotMCPPlugin")
	var ei = plugin.get_editor_interface()
	ei.get_resource_filesystem().scan()
