extends "res://addons/godot_mcp/tests/test_case.gd"

const FileTools = preload("res://addons/godot_mcp/tools/file_tools.gd")

const SANDBOX := "res://_filetools_test"

func _setup() -> void:
	_teardown()
	DirAccess.make_dir_recursive_absolute(SANDBOX + "/sub")
	_write(SANDBOX + "/a.txt", "hello world")
	_write(SANDBOX + "/needle.gd", "func find_me():\n\tpass\n")
	_write(SANDBOX + "/sub/b.txt", "another find_me here")

func _teardown() -> void:
	if DirAccess.dir_exists_absolute(SANDBOX):
		_rm_recursive(SANDBOX)

func _write(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f = null

func _rm_recursive(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var child := path + "/" + name
		if d.current_is_dir():
			_rm_recursive(child)
		else:
			DirAccess.remove_absolute(child)
		name = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)

func test_read_file_returns_content() -> void:
	_setup()
	var ft = FileTools.new()
	var r = ft.read_file({"path": "_filetools_test/a.txt"})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"], "hello world")
	_teardown()

func test_read_file_missing() -> void:
	_setup()
	var r = FileTools.new().read_file({"path": "_filetools_test/nope.txt"})
	assert_false(r["ok"])
	assert_has(r["error"], "not found")
	_teardown()

func test_read_file_rejects_traversal() -> void:
	var r = FileTools.new().read_file({"path": "../../etc/passwd"})
	assert_false(r["ok"])

func test_list_dir_lists_entries() -> void:
	_setup()
	var r = FileTools.new().list_dir({"path": "_filetools_test"})
	assert_true(r["ok"], str(r))
	var names := []
	for e in r["value"]:
		names.append(e["name"])
	assert_has(names, "a.txt")
	assert_has(names, "needle.gd")
	assert_has(names, "sub")
	# "sub" must be flagged as a directory.
	for e in r["value"]:
		if e["name"] == "sub":
			assert_true(e["is_dir"])
	_teardown()

func test_list_dir_missing() -> void:
	var r = FileTools.new().list_dir({"path": "_filetools_test/does_not_exist"})
	assert_false(r["ok"])

func test_search_project_finds_matches_recursively() -> void:
	_setup()
	var r = FileTools.new().search_project({"query": "find_me", "path": "_filetools_test"})
	assert_true(r["ok"], str(r))
	# Two files contain "find_me": needle.gd and sub/b.txt.
	var files := {}
	for m in r["value"]:
		files[m["file"]] = true
		assert_has(m["text"], "find_me")
		assert_true(m["line"] >= 1)
	assert_eq(files.size(), 2)
	_teardown()

func test_search_project_no_matches() -> void:
	_setup()
	var r = FileTools.new().search_project({"query": "zzz_nothing", "path": "_filetools_test"})
	assert_true(r["ok"])
	assert_eq(r["value"].size(), 0)
	_teardown()
