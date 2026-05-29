extends "res://addons/godot_mcp/tests/test_case.gd"

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

func test_normalize_adds_prefix() -> void:
	assert_eq(Paths.normalize("foo/bar.gd"), "res://foo/bar.gd")

func test_normalize_keeps_prefix() -> void:
	assert_eq(Paths.normalize("res://foo/bar.gd"), "res://foo/bar.gd")

func test_normalize_strips_leading_slash() -> void:
	assert_eq(Paths.normalize("/foo.gd"), "res://foo.gd")

func test_ensure_extension_adds_when_missing() -> void:
	assert_eq(Paths.ensure_extension("res://a/b", ".gd"), "res://a/b.gd")

func test_ensure_extension_keeps_when_present() -> void:
	assert_eq(Paths.ensure_extension("res://a/b.gd", ".gd"), "res://a/b.gd")

func test_validate_accepts_in_project() -> void:
	var r := Paths.validate("scripts/player.gd")
	assert_true(r["ok"], str(r))
	assert_eq(r["path"], "res://scripts/player.gd")

func test_validate_rejects_parent_traversal() -> void:
	var r := Paths.validate("res://../secret.txt")
	assert_false(r["ok"])
	assert_ne(r["error"], "")

func test_validate_rejects_embedded_traversal() -> void:
	var r := Paths.validate("scripts/../../etc/passwd")
	assert_false(r["ok"])
