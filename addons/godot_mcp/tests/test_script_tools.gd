extends "res://addons/godot_mcp/tests/test_case.gd"

const ScriptTools = preload("res://addons/godot_mcp/tools/script_tools.gd")

const SANDBOX := "res://_scripttools_test"

func _teardown() -> void:
	if DirAccess.dir_exists_absolute(SANDBOX):
		var d := DirAccess.open(SANDBOX)
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if not d.current_is_dir():
				DirAccess.remove_absolute(SANDBOX + "/" + name)
			name = d.get_next()
		d.list_dir_end()
		DirAccess.remove_absolute(SANDBOX)

func test_create_script_writes_file_and_dirs() -> void:
	_teardown()
	var st = ScriptTools.new()
	var r = st.create_script({"path": "_scripttools_test/player.gd", "content": "extends Node\n"})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"]["path"], "res://_scripttools_test/player.gd")
	assert_true(FileAccess.file_exists("res://_scripttools_test/player.gd"))
	assert_eq(FileAccess.open("res://_scripttools_test/player.gd", FileAccess.READ).get_as_text(), "extends Node\n")
	_teardown()

func test_create_script_adds_gd_extension() -> void:
	_teardown()
	var r = ScriptTools.new().create_script({"path": "_scripttools_test/foo", "content": "extends Node\n"})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"]["path"], "res://_scripttools_test/foo.gd")
	_teardown()

func test_edit_script_requires_existing_file() -> void:
	_teardown()
	var r = ScriptTools.new().edit_script({"path": "_scripttools_test/missing.gd", "content": "x"})
	assert_false(r["ok"])
	assert_has(r["error"], "not found")
	_teardown()

func test_edit_script_overwrites() -> void:
	_teardown()
	var st = ScriptTools.new()
	st.create_script({"path": "_scripttools_test/e.gd", "content": "extends Node\n"})
	var r = st.edit_script({"path": "_scripttools_test/e.gd", "content": "extends Node2D\n"})
	assert_true(r["ok"], str(r))
	assert_eq(FileAccess.open("res://_scripttools_test/e.gd", FileAccess.READ).get_as_text(), "extends Node2D\n")
	_teardown()

func test_validate_script_accepts_valid_source() -> void:
	var r = ScriptTools.new().validate_script({"content": "extends Node\nfunc _ready():\n\tprint(1)\n"})
	assert_true(r["ok"], str(r))
	assert_true(r["value"]["valid"])
	assert_eq(r["value"]["errors"].size(), 0)

func test_validate_script_reports_parse_error_with_line() -> void:
	# Missing ':' after func signature is a parse error.
	var r = ScriptTools.new().validate_script({"content": "extends Node\nfunc bad(\n\tpass\n"})
	assert_true(r["ok"], str(r))
	assert_false(r["value"]["valid"])
	assert_true(r["value"]["errors"].size() >= 1)
	assert_true(r["value"]["errors"][0]["line"] >= 1)
	assert_ne(r["value"]["errors"][0]["message"], "")

func test_validate_script_from_file() -> void:
	_teardown()
	var st = ScriptTools.new()
	st.create_script({"path": "_scripttools_test/v.gd", "content": "extends Node\n"})
	var r = st.validate_script({"path": "_scripttools_test/v.gd"})
	assert_true(r["ok"], str(r))
	assert_true(r["value"]["valid"])
	_teardown()
