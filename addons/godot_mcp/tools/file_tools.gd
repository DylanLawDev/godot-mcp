@tool
extends RefCounted

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

const _MAX_RESULTS := 200          # cap search hits
const _MAX_FILE_BYTES := 1_000_000 # skip files larger than ~1MB during search

func read_file(args: Dictionary) -> Dictionary:
	var v := Paths.validate(str(args.get("path", "")))
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var path: String = v["path"]
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: " + path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Cannot open file: " + path}
	var content := f.get_as_text()
	f = null
	return {"ok": true, "value": content}

func list_dir(args: Dictionary) -> Dictionary:
	var v := Paths.validate(str(args.get("path", "")))
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var path: String = v["path"]
	var d := DirAccess.open(path)
	if d == null:
		return {"ok": false, "error": "Directory not found: " + path}
	var entries := []
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		entries.append({
			"name": name,
			"path": path.path_join(name),
			"is_dir": d.current_is_dir(),
		})
		name = d.get_next()
	d.list_dir_end()
	return {"ok": true, "value": entries}

func search_project(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", ""))
	if query == "":
		return {"ok": false, "error": "query is required"}
	var root := str(args.get("path", "res://"))
	var v := Paths.validate(root)
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var matches := []
	_search_dir(v["path"], query, matches)
	return {"ok": true, "value": matches}

func _search_dir(dir_path: String, query: String, matches: Array) -> void:
	if matches.size() >= _MAX_RESULTS:
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var child := dir_path.path_join(name)
		if d.current_is_dir():
			_search_dir(child, query, matches)
		else:
			_search_file(child, query, matches)
		if matches.size() >= _MAX_RESULTS:
			break
		name = d.get_next()
	d.list_dir_end()

func _search_file(file_path: String, query: String, matches: Array) -> void:
	if not FileAccess.file_exists(file_path):
		return
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return
	if f.get_length() > _MAX_FILE_BYTES:
		f = null
		return
	var line_no := 0
	while not f.eof_reached():
		var line := f.get_line()
		line_no += 1
		if line.find(query) != -1:
			matches.append({"file": file_path, "line": line_no, "text": line})
			if matches.size() >= _MAX_RESULTS:
				break
	f = null
