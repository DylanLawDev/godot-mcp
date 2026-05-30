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

func test_strip_class_name_blanks_declaration_preserving_lines() -> void:
	var src := "@tool\nclass_name Foo\nextends Node\n"
	var out: String = ScriptTools._strip_class_name(src)
	# Line count is preserved (declaration line blanked, not deleted).
	assert_eq(out.split("\n").size(), src.split("\n").size())
	assert_false("class_name" in out)
	assert_has(out, "@tool")
	assert_has(out, "extends Node")

func test_strip_class_name_noop_without_declaration() -> void:
	var src := "extends Node\nfunc _ready():\n\tpass\n"
	assert_eq(ScriptTools._strip_class_name(src), src)

func test_validate_script_with_class_name_stays_valid() -> void:
	var r = ScriptTools.new().validate_script({"content": "class_name McpFixtureValid\nextends Node\nfunc _ready():\n\tprint(1)\n"})
	assert_true(r["ok"], str(r))
	assert_true(r["value"]["valid"], str(r))

func test_validate_script_class_name_with_error_keeps_correct_line() -> void:
	# class_name on line 1, parse error on line 3 — stripping must blank line 1,
	# not delete it, so the reported error line is not shifted.
	var r = ScriptTools.new().validate_script({"content": "class_name McpFixtureErr\nextends Node\nfunc bad(\n\tpass\n"})
	assert_true(r["ok"], str(r))
	assert_false(r["value"]["valid"])
	assert_true(r["value"]["errors"].size() >= 1)
	assert_true(r["value"]["errors"][0]["line"] >= 3)

# --- list_scripts ---

func test_list_scripts_walks_examples() -> void:
	var r = ScriptTools.new().list_scripts({"path": "res://examples"})
	assert_true(r["ok"], str(r))
	var scripts: Array = r["value"]["scripts"]
	assert_true(scripts.size() >= 1, str(r))
	var found_gd := false
	for s in scripts:
		assert_true(str(s["path"]).ends_with(".gd"), str(s))
		if str(s["path"]).ends_with("player.gd"):
			found_gd = true
			assert_eq(s["extends"], "CharacterBody2D")
	assert_true(found_gd, str(scripts))

func test_list_scripts_rejects_traversal() -> void:
	var r = ScriptTools.new().list_scripts({"path": "../etc"})
	assert_false(r["ok"], str(r))

# Review fix (PR #7): a misspelled / non-directory root errors rather than reporting
# an empty result, so a typo can't be mistaken for "no scripts here".
func test_list_scripts_rejects_missing_root() -> void:
	var r = ScriptTools.new().list_scripts({"path": "res://no_such_dir_xyz"})
	assert_false(r["ok"], str(r))
	# A path that points at a file (not a directory) is rejected too.
	var r2 = ScriptTools.new().list_scripts({"path": "res://examples/data/notes.txt"})
	assert_false(r2["ok"], str(r2))

func test_parse_script_header_extracts_class_name_and_extends() -> void:
	var h = ScriptTools._parse_script_header("@tool\nclass_name Foo\nextends Node2D\nfunc _ready():\n\tpass\n")
	assert_eq(h["class_name"], "Foo")
	assert_eq(h["extends"], "Node2D")

func test_parse_script_header_empty_when_absent() -> void:
	var h = ScriptTools._parse_script_header("func _ready():\n\tpass\n")
	assert_eq(h["class_name"], "")
	assert_eq(h["extends"], "")

func test_parse_script_header_single_line_class_name_extends() -> void:
	var h = ScriptTools._parse_script_header("class_name Foo extends Node2D\n")
	assert_eq(h["class_name"], "Foo")
	assert_eq(h["extends"], "Node2D")

func test_parse_script_header_ignores_indented_inner_class_extends() -> void:
	# An indented `extends` inside an inner class body is not the top-level base.
	var h = ScriptTools._parse_script_header("extends Node\nclass Inner:\n\textends RefCounted\n")
	assert_eq(h["extends"], "Node")

# --- get_open_scripts ---

func test_get_open_scripts_headless_empty() -> void:
	var r = ScriptTools.new().get_open_scripts({})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"]["scripts"], [])
	assert_eq(r["value"]["current"], null)

# --- edit_script find/replace (_apply_edit pure logic) ---

func test_apply_edit_full_content() -> void:
	var r = ScriptTools.new()._apply_edit("old\n", {"content": "new\n"})
	assert_true(r["ok"], str(r))
	assert_eq(r["text"], "new\n")

func test_apply_edit_single_replace() -> void:
	var r = ScriptTools.new()._apply_edit("var a = 1\n", {"find": "a = 1", "replace": "a = 2"})
	assert_true(r["ok"], str(r))
	assert_eq(r["text"], "var a = 2\n")

func test_apply_edit_find_not_found_errors() -> void:
	var r = ScriptTools.new()._apply_edit("var a = 1\n", {"find": "nope"})
	assert_false(r["ok"])
	assert_has(r["error"], "not found")

func test_apply_edit_both_content_and_find_errors() -> void:
	var r = ScriptTools.new()._apply_edit("x", {"content": "y", "find": "x"})
	assert_false(r["ok"])
	assert_has(r["error"], "not both")

func test_apply_edit_neither_errors() -> void:
	var r = ScriptTools.new()._apply_edit("x", {})
	assert_false(r["ok"])
	assert_has(r["error"], "Provide")

func test_apply_edit_multiple_without_replace_all_errors() -> void:
	var r = ScriptTools.new()._apply_edit("a a a\n", {"find": "a", "replace": "b"})
	assert_false(r["ok"])
	assert_has(r["error"], "occurrences")

func test_apply_edit_multiple_with_replace_all() -> void:
	var r = ScriptTools.new()._apply_edit("a a a\n", {"find": "a", "replace": "b", "replace_all": true})
	assert_true(r["ok"], str(r))
	assert_eq(r["text"], "b b b\n")

func test_apply_edit_replace_defaults_empty() -> void:
	var r = ScriptTools.new()._apply_edit("xREMOVEy", {"find": "REMOVE"})
	assert_true(r["ok"], str(r))
	assert_eq(r["text"], "xy")

func test_apply_edit_empty_find_errors() -> void:
	var r = ScriptTools.new()._apply_edit("x", {"find": ""})
	assert_false(r["ok"])
	assert_has(r["error"], "must not be empty")

func test_edit_script_find_replace_on_file() -> void:
	_teardown()
	var st = ScriptTools.new()
	st.create_script({"path": "_scripttools_test/fr.gd", "content": "extends Node\nvar speed = 1\n"})
	var r = st.edit_script({"path": "_scripttools_test/fr.gd", "find": "speed = 1", "replace": "speed = 9"})
	assert_true(r["ok"], str(r))
	assert_eq(FileAccess.open("res://_scripttools_test/fr.gd", FileAccess.READ).get_as_text(), "extends Node\nvar speed = 9\n")
	_teardown()
