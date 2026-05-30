extends "res://addons/godot_mcp/tests/test_case.gd"

const UidTools = preload("res://addons/godot_mcp/tools/uid_tools.gd")

const SANDBOX := "res://_uidtools_test"

func _setup() -> void:
	_teardown()
	DirAccess.make_dir_recursive_absolute(SANDBOX)
	DirAccess.make_dir_recursive_absolute(SANDBOX + "/sub")

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
	# Include hidden dirs so .hidden subdirectories are removed too.
	d.include_hidden = true
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

# Write a minimal valid resource to disk via ResourceSaver so it can be resaved.
# Uses PackedScene for .tscn files; Resource for .tres/.res.
func _write_resource(path: String) -> bool:
	var err: int
	if path.ends_with(".tscn"):
		var ps := PackedScene.new()
		var n := Node.new()
		n.name = "Root"
		ps.pack(n)
		n.free()
		err = ResourceSaver.save(ps, path)
	else:
		err = ResourceSaver.save(Resource.new(), path)
	return err == OK

# --- get_uid ---

func test_get_uid_rejects_traversal() -> void:
	var r := UidTools.new().get_uid({"path": "../../etc/passwd"})
	assert_false(r["ok"], str(r))
	assert_has(r["error"], "escapes")

func test_get_uid_rejects_empty_path() -> void:
	var r := UidTools.new().get_uid({"path": ""})
	assert_false(r["ok"], str(r))

func test_get_uid_missing_file_errors() -> void:
	var r := UidTools.new().get_uid({"path": "res://_no_such_file_xyz.tres"})
	assert_false(r["ok"], str(r))
	assert_has(r["error"], "not found")

func test_get_uid_no_uid_registered_errors() -> void:
	# Write a raw text file that is NOT a resource (no UID in the registry).
	_setup()
	_write(SANDBOX + "/raw.tres", "[gd_resource format=3]\n")
	var r := UidTools.new().get_uid({"path": SANDBOX + "/raw.tres"})
	# The file exists but has no UID in the registry — expect error with "No UID for".
	assert_false(r["ok"], str(r))
	assert_has(r["error"], "No UID for")
	_teardown()

func test_get_uid_returns_uid_after_resource_save() -> void:
	# Headlessly, ResourceSaver.save does not populate the UID registry.
	# Manually register a UID for a path to test the get_uid happy path.
	_setup()
	var path := SANDBOX + "/valid.tres"
	assert_true(_write_resource(path), "ResourceSaver.save failed")
	var uid_val := ResourceUID.create_id()
	ResourceUID.add_id(uid_val, path)
	var r := UidTools.new().get_uid({"path": path})
	assert_true(r["ok"], str(r))
	assert_true(str(r["value"]["uid"]).begins_with("uid://"), str(r))
	assert_eq(r["value"]["path"], path)
	ResourceUID.remove_id(uid_val)
	_teardown()

# --- update_project_uids ---

func test_update_project_uids_rejects_traversal() -> void:
	var r := UidTools.new().update_project_uids({"path": "../../etc"})
	assert_false(r["ok"], str(r))

func test_update_project_uids_rejects_missing_root() -> void:
	var r := UidTools.new().update_project_uids({"path": "res://_no_such_dir_xyz"})
	assert_false(r["ok"], str(r))

func _snapshot_resources(dir: String, out: Dictionary) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name != "." and name != "..":
			var full := dir.path_join(name)
			if d.current_is_dir():
				if not d.is_link(full):
					_snapshot_resources(full, out)
			elif name.ends_with(".tscn") or name.ends_with(".tres") or name.ends_with(".res"):
				out[full] = FileAccess.get_file_as_bytes(full)
		name = d.get_next()
	d.list_dir_end()

# Walk `dir` recursively and collect the path of every .uid file into `out` (a Dictionary
# used as a set: keys are paths, values are true). Skips symlinked dirs.
func _snapshot_uid_paths(dir: String, out: Dictionary) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name != "." and name != "..":
			var full := dir.path_join(name)
			if d.current_is_dir():
				if not d.is_link(full):
					_snapshot_uid_paths(full, out)
			elif name.ends_with(".uid"):
				out[full] = true
		name = d.get_next()
	d.list_dir_end()

func test_update_project_uids_default_path_runs_without_error() -> void:
	# Call with NO args to exercise the args.get("path", "res://") default branch.
	# This walks the real project tree (res://); it may resave tracked files. Snapshot
	# all resource bytes beforehand and restore them afterward so the working tree is
	# left byte-identical regardless of what resources exist in the project.
	# Also snapshot existing .uid sidecar paths so any new ones created by the resave
	# can be detected and deleted, keeping the working tree clean.
	var snapshot: Dictionary = {}
	_snapshot_resources("res://", snapshot)
	var uid_before: Dictionary = {}
	_snapshot_uid_paths("res://", uid_before)
	var r := UidTools.new().update_project_uids({})
	# Restore all resource bytes to their pre-call state.
	for path: String in snapshot:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(snapshot[path])
		f = null
	# Remove any .uid sidecar files that were created during the tool call.
	var uid_after: Dictionary = {}
	_snapshot_uid_paths("res://", uid_after)
	for uid_path: String in uid_after:
		if not uid_before.has(uid_path):
			DirAccess.remove_absolute(uid_path)
	# Assert: the .uid set is back to its pre-call state (no strays remain).
	var uid_final: Dictionary = {}
	_snapshot_uid_paths("res://", uid_final)
	assert_eq(uid_final.size(), uid_before.size(), "uid sidecar set must be identical after restore")
	assert_true(r["ok"], str(r))
	var v: Dictionary = r["value"]
	assert_true(v.has("scanned"), str(v))
	assert_true(v.has("resaved"), str(v))
	assert_true(v.has("failed"), str(v))
	assert_true(v["scanned"] is int and v["scanned"] >= 0, "scanned must be int >= 0: " + str(v))

func test_update_project_uids_counts_valid_resources() -> void:
	_setup()
	# Write two valid .tres resources.
	assert_true(_write_resource(SANDBOX + "/a.tres"), "save a.tres")
	assert_true(_write_resource(SANDBOX + "/b.tres"), "save b.tres")
	var r := UidTools.new().update_project_uids({"path": SANDBOX})
	assert_true(r["ok"], str(r))
	var v: Dictionary = r["value"]
	assert_eq(v["scanned"], 2, "expected 2 scanned, got %d" % v["scanned"])
	assert_eq(v["resaved"], 2, "expected 2 resaved, got %d" % v["resaved"])
	assert_eq(v["failed"].size(), 0, "expected no failures")
	_teardown()

func test_update_project_uids_recurses_into_subdirs() -> void:
	_setup()
	assert_true(_write_resource(SANDBOX + "/top.tres"), "save top.tres")
	assert_true(_write_resource(SANDBOX + "/sub/nested.tres"), "save nested.tres")
	var r := UidTools.new().update_project_uids({"path": SANDBOX})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"]["scanned"], 2, str(r["value"]))
	_teardown()

func test_update_project_uids_corrupt_resource_goes_to_failed() -> void:
	_setup()
	# Write a valid resource and a deliberately corrupt .tres file.
	assert_true(_write_resource(SANDBOX + "/good.tres"), "save good.tres")
	_write(SANDBOX + "/corrupt.tres", "this is not a valid resource file\n")
	var r := UidTools.new().update_project_uids({"path": SANDBOX})
	assert_true(r["ok"], str(r))  # ok=true even when some files fail
	var v: Dictionary = r["value"]
	assert_eq(v["scanned"], 2, str(v))
	# The corrupt file should fail; the good one should succeed.
	assert_eq(v["resaved"], 1, str(v))
	assert_eq(v["failed"].size(), 1, str(v))
	var fail_entry: Dictionary = v["failed"][0]
	assert_true(fail_entry.has("path"), str(fail_entry))
	assert_true(fail_entry.has("error"), str(fail_entry))
	assert_has(str(fail_entry["path"]), "corrupt")
	_teardown()

func test_update_project_uids_skips_hidden_dirs() -> void:
	_setup()
	# Create a hidden dir with a .tres inside — it must NOT be scanned.
	DirAccess.make_dir_recursive_absolute(SANDBOX + "/.hidden")
	assert_true(_write_resource(SANDBOX + "/.hidden/secret.tres"), "save secret.tres")
	assert_true(_write_resource(SANDBOX + "/visible.tres"), "save visible.tres")
	var r := UidTools.new().update_project_uids({"path": SANDBOX})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"]["scanned"], 1, "hidden dir must be skipped: " + str(r["value"]))
	_teardown()

func test_update_project_uids_scans_tscn_and_res_extensions() -> void:
	_setup()
	# Write files with all three expected extensions.
	assert_true(_write_resource(SANDBOX + "/scene.tscn"), "save scene.tscn")
	assert_true(_write_resource(SANDBOX + "/binary.res"), "save binary.res")
	assert_true(_write_resource(SANDBOX + "/data.tres"), "save data.tres")
	# A .gd file must NOT be counted.
	_write(SANDBOX + "/script.gd", "extends Node\n")
	var r := UidTools.new().update_project_uids({"path": SANDBOX})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"]["scanned"], 3, str(r["value"]))
	_teardown()
