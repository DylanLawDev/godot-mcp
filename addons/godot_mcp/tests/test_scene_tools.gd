extends "res://addons/godot_mcp/tests/test_case.gd"

const SceneTools = preload("res://addons/godot_mcp/tools/scene_tools.gd")

# Headless: no edited scene exists, so every public tool reports it.
func test_get_scene_tree_no_scene_open() -> void:
	var st = SceneTools.new()
	var r: Dictionary = st.get_scene_tree({})
	assert_false(r["ok"])
	assert_eq(r["error"], "No scene is currently open")

func test_get_node_properties_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.get_node_properties({"path": "."})["ok"])

func test_create_node_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.create_node({"parent_path": ".", "type": "Node"})["ok"])

func test_delete_node_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.delete_node({"path": "Foo"})["ok"])

func test_modify_node_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.modify_node({"path": ".", "properties": {}})["ok"])

func test_duplicate_node_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.duplicate_node({"path": "Foo"})["ok"])

func test_move_node_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.move_node({"path": "Foo", "new_parent_path": "."})["ok"])

func test_rename_node_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.rename_node({"path": "Foo", "name": "Bar"})["ok"])

func test_get_signals_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.get_signals({"path": "."})["ok"])

func test_connect_signal_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.connect_signal({"from_path": "A", "signal": "renamed", "to_path": "B", "method": "queue_free"})["ok"])

func test_disconnect_signal_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.disconnect_signal({"from_path": "A", "signal": "renamed", "to_path": "B", "method": "queue_free"})["ok"])

func test_get_node_groups_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.get_node_groups({"path": "."})["ok"])

func test_set_node_groups_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.set_node_groups({"path": ".", "groups": []})["ok"])

func test_find_nodes_in_group_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.find_nodes_in_group({"group": "enemies"})["ok"])

func test_add_resource_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.add_resource({"path": ".", "property": "shape", "type": "RectangleShape2D"})["ok"])

func test_set_anchor_preset_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.set_anchor_preset({"path": ".", "preset": 15})["ok"])

func test_attach_script_no_scene_open() -> void:
	var st = SceneTools.new()
	assert_false(st.attach_script({"path": ".", "script_path": "res://examples/scripts/player.gd"})["ok"])

# Build a detached tree:  Root -> [Child (Node2D), Branch -> Leaf]
func _make_tree() -> Node:
	var root := Node.new()
	root.name = "Root"
	var child := Node2D.new()
	child.name = "Child"
	root.add_child(child)
	var branch := Node.new()
	branch.name = "Branch"
	root.add_child(branch)
	var leaf := Node.new()
	leaf.name = "Leaf"
	branch.add_child(leaf)
	return root

func test_serialize_tree_shape_and_paths() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var tree: Dictionary = st._serialize_tree(root, root)
	assert_eq(tree["name"], "Root")
	assert_eq(tree["type"], "Node")
	assert_eq(tree["path"], ".")
	assert_eq(tree["children"].size(), 2)
	var child: Dictionary = tree["children"][0]
	assert_eq(child["name"], "Child")
	assert_eq(child["type"], "Node2D")
	assert_eq(child["path"], "Child")
	assert_eq(child["script"], null)
	var branch: Dictionary = tree["children"][1]
	assert_eq(branch["children"][0]["path"], "Branch/Leaf")
	root.free()

func test_resolve_root_and_nested_and_missing() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	assert_eq(st._resolve(root, "."), root)
	assert_eq(st._resolve(root, "Branch/Leaf").name, "Leaf")
	assert_eq(st._resolve(root, "Nope/Missing"), null)
	root.free()

func test_encode_props_includes_value_and_skips_separators() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	n.position = Vector2(3, 4)
	var props: Dictionary = st._encode_props(n)
	# position round-trips through var_to_str
	assert_true(props.has("position"))
	assert_eq(props["position"], var_to_str(Vector2(3, 4)))
	# Category/group separator rows (e.g. "Node2D", "Transform") are not real props.
	assert_false(props.has("Node2D"))
	n.free()

func test_attach_sets_parent_and_owner() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var n := Node.new()
	n.name = "New"
	st._attach(root, n, root)
	assert_eq(n.get_parent(), root)
	assert_eq(n.owner, root)
	root.free()

func test_detach_removes_child() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var leaf := st._resolve(root, "Branch/Leaf")
	var parent := leaf.get_parent()
	st._detach(parent, leaf)
	assert_eq(leaf.get_parent(), null)
	assert_eq(parent.get_child_count(), 0)
	leaf.free()  # _detach does not free; we own it now
	root.free()

func test_apply_props_sets_known_reports_unknown() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	var res: Dictionary = st._apply_props(n, {"position": var_to_str(Vector2(5, 6)), "bogus_xyz": "1"})
	assert_eq(n.position, Vector2(5, 6))
	assert_has(res["set"], "position")
	assert_eq(res["errors"].size(), 1)
	assert_eq(res["errors"][0]["name"], "bogus_xyz")
	n.free()

func test_make_node_validates_type() -> void:
	var st = SceneTools.new()
	# Valid instantiable Node subclass:
	var ok_node := st._make_node("Node2D", "Thing")
	assert_ne(ok_node, null)
	assert_eq(ok_node.name, "Thing")
	ok_node.free()
	# Not a Node (Resource) and a bogus class both reject:
	assert_eq(st._make_node("Resource", ""), null)
	assert_eq(st._make_node("NotARealClass", ""), null)

func test_decode_props_separates_valid_and_unknown() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	var d: Dictionary = st._decode_props(n, {"position": var_to_str(Vector2(1, 2)), "bogus": "1"})
	assert_eq(d["valid"].size(), 1)
	assert_eq(d["valid"][0]["name"], "position")
	assert_eq(d["valid"][0]["value"], Vector2(1, 2))
	assert_eq(d["errors"].size(), 1)
	assert_eq(d["errors"][0]["name"], "bogus")
	n.free()

func test_apply_props_reports_type_mismatch_as_error() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	# A String value cannot apply to a Vector2 property: Godot drops it silently.
	var res: Dictionary = st._apply_props(n, {"position": var_to_str("hello")})
	assert_eq(res["set"].size(), 0)
	assert_eq(res["errors"].size(), 1)
	assert_eq(res["errors"][0]["name"], "position")
	n.free()

func test_apply_props_allows_int_to_float_coercion() -> void:
	var st = SceneTools.new()
	var n := Node2D.new()
	var res: Dictionary = st._apply_props(n, {"rotation": var_to_str(2)})  # rotation is float
	assert_has(res["set"], "rotation")
	assert_eq(res["errors"].size(), 0)
	n.free()

func test_scene_current_resource_reports_closed_headless() -> void:
	var st = SceneTools.new()
	var r: Dictionary = st.scene_current({})
	assert_true(r["ok"])
	assert_eq(r["value"], {"open": false})

func test_script_current_resource_reports_closed_headless() -> void:
	var st = SceneTools.new()
	var r: Dictionary = st.script_current({})
	assert_true(r["ok"])
	assert_eq(r["value"], {"open": false})

# A NodePath that escapes the edited scene (e.g. "..") must not resolve to an
# outside node, even when the scene root has a parent (as it does in the editor).
func test_resolve_rejects_parent_escape() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var outer := Node.new()
	outer.add_child(root)  # give root a parent so ".." resolves outside the scene
	assert_eq(st._resolve(root, ".."), null)
	outer.free()  # frees root + its subtree too

func test_resolve_rejects_absolute_path() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	assert_eq(st._resolve(root, "/root"), null)
	root.free()

# Deleting a middle child and undoing must restore its sibling index AND the
# ownership of the whole removed subtree (Godot may clear owner on tree-exit).
func test_capture_and_restore_owners_and_index() -> void:
	var st = SceneTools.new()
	var R := Node.new(); R.name = "R"
	var A0 := Node.new(); A0.name = "A0"; R.add_child(A0); A0.owner = R
	var MID := Node.new(); MID.name = "MID"; R.add_child(MID); MID.owner = R
	var GC := Node.new(); GC.name = "GC"; MID.add_child(GC); GC.owner = R
	var A2 := Node.new(); A2.name = "A2"; R.add_child(A2); A2.owner = R
	var idx := MID.get_index()  # 1
	var owners := st._capture_owners(MID)
	# Simulate the live-editor delete: subtree leaves the tree and loses owners.
	R.remove_child(MID)
	MID.owner = null
	GC.owner = null
	st._restore(R, MID, idx, owners)
	assert_eq(MID.get_index(), 1)
	assert_eq(MID.owner, R)
	assert_eq(GC.owner, R)
	R.free()

# Task 1.1: create_node's property application is factored into _apply_props (reused
# from modify_node). A newly-attached node with props gets them set and owned by root.
func test_apply_props_on_attached_node() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var n := Node2D.new()
	n.name = "Made"
	st._attach(root, n, root)
	var res: Dictionary = st._apply_props(n, {"position": var_to_str(Vector2(7, 8))})
	assert_eq(n.position, Vector2(7, 8))
	assert_has(res["set"], "position")
	assert_eq(n.owner, root)
	root.free()

# Task 1.2: _set_owner_recursive roots an entire duplicated subtree at the scene root.
func test_set_owner_recursive_covers_descendants() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var branch := st._resolve(root, "Branch")  # Branch -> Leaf
	var dup: Node = branch.duplicate()
	root.add_child(dup)
	st._set_owner_recursive(dup, root)
	assert_true(dup.get_child_count() > 0)
	assert_eq(dup.owner, root)
	for c in dup.get_children():
		assert_eq(c.owner, root)
	root.free()

# Task 1.3: reparenting moves a node under a new parent; owner stays the scene root.
func test_reparent_keeps_owner() -> void:
	var root := Node.new(); root.name = "Root"
	var a := Node.new(); a.name = "A"; root.add_child(a); a.owner = root
	var b := Node.new(); b.name = "B"; root.add_child(b); b.owner = root
	a.owner = null  # avoid the editor "owner inconsistent" warning during reparent
	a.reparent(b, false)
	a.owner = root
	assert_eq(a.get_parent(), b)
	assert_eq(a.owner, root)
	root.free()

# Task 1.3: a node is an ancestor of its own descendant, so move_node's guard rejects it.
func test_move_into_own_descendant_guard() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var branch := st._resolve(root, "Branch")
	var leaf := st._resolve(root, "Branch/Leaf")
	assert_true(branch.is_ancestor_of(leaf))
	root.free()

# Task 2.1: _encode_signals reports a connection's target path + method, with the
# target path expressed relative to the scene root.
func test_encode_signals_reports_connection() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var child := st._resolve(root, "Child")  # Node2D, has "ready" signal
	var leaf := st._resolve(root, "Branch/Leaf")
	# Connect Child.renamed -> Leaf.queue_free (queue_free exists on every Node).
	child.connect("renamed", Callable(leaf, "queue_free"))
	var sigs: Array = st._encode_signals(child, root)
	var found := {}
	for s in sigs:
		for c in s["connections"]:
			found[str(s["name"]) + "->" + str(c["method"])] = c["target_path"]
	assert_true(found.has("renamed->queue_free"))
	assert_eq(found["renamed->queue_free"], "Branch/Leaf")
	root.free()

# Task 2.3: _connection_flags recovers a connection's original ConnectFlags so a
# disconnect's undo restores it exactly (not a hardcoded CONNECT_PERSIST).
func test_connection_flags_recovers_original() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var child := st._resolve(root, "Child")
	var leaf := st._resolve(root, "Branch/Leaf")
	var cb := Callable(leaf, "queue_free")
	var flags := Object.CONNECT_PERSIST | Object.CONNECT_ONE_SHOT
	child.connect("renamed", cb, flags)
	assert_eq(st._connection_flags(child, "renamed", cb), flags)
	# An absent connection falls back to CONNECT_PERSIST.
	assert_eq(st._connection_flags(child, "ready", cb), Object.CONNECT_PERSIST)
	root.free()

# Task 2.6: _load_script validates the path and loads a real Script; rejects
# traversal, missing files and non-script resources.
func test_load_script_validates_and_loads() -> void:
	var st = SceneTools.new()
	var ok_res: Dictionary = st._load_script("res://examples/scripts/player.gd")
	assert_true(ok_res["ok"])
	assert_true(ok_res["value"] is Script)
	# Traversal rejected by Paths.validate.
	assert_false(st._load_script("res://../etc/passwd")["ok"])
	# Missing file rejected.
	assert_false(st._load_script("res://examples/scripts/nope_missing.gd")["ok"])
	# A non-script resource is not a Script.
	assert_false(st._load_script("res://examples/data/notes.txt")["ok"])

# Task 2.5: _resolve_preset maps int passthrough + name variants to LayoutPreset ints.
func test_resolve_preset_name_and_int() -> void:
	var st = SceneTools.new()
	assert_eq(st._resolve_preset(15), 15)
	assert_eq(st._resolve_preset("PRESET_FULL_RECT"), 15)
	assert_eq(st._resolve_preset("full_rect"), 15)
	assert_eq(st._resolve_preset("center"), 8)
	assert_eq(st._resolve_preset("CENTER"), 8)
	assert_eq(st._resolve_preset("not_a_preset"), -1)

# Task 2.4: _make_resource validates the type is an instantiable Resource subclass.
func test_make_resource_validates_type() -> void:
	var st = SceneTools.new()
	var ok_res: Dictionary = st._make_resource("RectangleShape2D")
	assert_true(ok_res["ok"])
	assert_true(ok_res["value"] is Resource)
	# A Node is not a Resource; a bogus class does not exist.
	assert_false(st._make_resource("Node2D")["ok"])
	assert_false(st._make_resource("NotARealClass")["ok"])

# Task 2.4: a built resource assigns onto a real Resource property of a node.
func test_make_resource_assigns_onto_node_property() -> void:
	var st = SceneTools.new()
	var node := CollisionShape2D.new()
	var res: Resource = st._make_resource("RectangleShape2D")["value"]
	node.set("shape", res)
	assert_eq(node.shape, res)
	node.free()

# Task 2.3: _find_in_group walks a detached subtree and returns the root-relative
# paths of exactly the nodes that are in the group.
func test_find_in_group_collects_matching_paths() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	st._resolve(root, "Child").add_to_group("enemies", true)
	st._resolve(root, "Branch/Leaf").add_to_group("enemies", true)
	st._resolve(root, "Branch").add_to_group("walls", true)
	var out := []
	st._find_in_group(root, root, "enemies", out)
	assert_eq(out.size(), 2)
	assert_has(out, "Child")
	assert_has(out, "Branch/Leaf")
	root.free()

# Task 2.3: _group_diff computes which groups to add vs remove given current/desired.
func test_group_diff_added_and_removed() -> void:
	var st = SceneTools.new()
	var d: Dictionary = st._group_diff(["a", "b"], ["b", "c"])
	assert_eq(d["added"], ["c"])
	assert_eq(d["removed"], ["a"])

# Review fix (PR #6): internal "_"-prefixed groups are reserved by Godot and must
# never be removed by set_node_groups, even when absent from the desired list.
func test_group_diff_preserves_internal_groups() -> void:
	var st = SceneTools.new()
	var d: Dictionary = st._group_diff(["_edit_lock_", "enemies"], ["walls"])
	assert_has(d["added"], "walls")
	assert_has(d["removed"], "enemies")
	assert_false(d["removed"].has("_edit_lock_"))

# Review fix (PR #6): _find_connection returns the real (possibly bound) callable so a
# connection made with bound args can still be located and disconnected.
func test_find_connection_matches_bound_callable() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var child := st._resolve(root, "Child")
	var leaf := st._resolve(root, "Branch/Leaf")
	var bound := Callable(leaf, "set_process").bind(true)
	child.connect("renamed", bound)
	var found := st._find_connection(child, "renamed", leaf, "set_process")
	assert_false(found.is_null())
	# It recovered the ACTUAL bound callable (carries its bind), which is what
	# disconnect() requires — a freshly built Callable(target, method) has no binds
	# and disconnect would reject it.
	assert_eq(found.get_bound_arguments_count(), 1)
	child.disconnect("renamed", found)
	assert_false(child.is_connected("renamed", found))
	# No matching connection yields an empty Callable.
	assert_true(st._find_connection(child, "ready", leaf, "set_process").is_null())
	root.free()

# Review fix (PR #6): attach_script must reject scripts whose native base is
# incompatible with the target node.
func test_script_compatible_checks_base_type() -> void:
	var st = SceneTools.new()
	assert_true(st._script_compatible("Sprite2D", "Node2D"))   # subclass of base
	assert_true(st._script_compatible("Node2D", "Node2D"))      # exact base
	assert_false(st._script_compatible("Control", "Node2D"))    # unrelated branch
	assert_true(st._script_compatible("Control", ""))           # no declared base

# Review fix (PR #6): add_resource must reject a resource the property can't accept.
func test_resource_assignable_respects_property_class() -> void:
	var st = SceneTools.new()
	assert_true(st._resource_assignable("RectangleShape2D", TYPE_OBJECT, "Shape2D"))
	assert_false(st._resource_assignable("RectangleShape2D", TYPE_OBJECT, "Texture2D"))
	assert_false(st._resource_assignable("RectangleShape2D", TYPE_INT, ""))   # not an object prop
	assert_true(st._resource_assignable("RectangleShape2D", TYPE_OBJECT, "")) # untyped object prop

# Task 2.2: connecting then disconnecting a signal flips is_connected, using the
# same Godot primitives the live-editor do/undo branches invoke.
func test_connect_disconnect_primitives() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var child := st._resolve(root, "Child")
	var leaf := st._resolve(root, "Branch/Leaf")
	var cb := Callable(leaf, "queue_free")
	assert_false(child.is_connected("renamed", cb))
	child.connect("renamed", cb, Object.CONNECT_PERSIST)
	assert_true(child.is_connected("renamed", cb))
	child.disconnect("renamed", cb)
	assert_false(child.is_connected("renamed", cb))
	root.free()

# Task 1.4: renaming sets the node name (we read it back since Godot may de-dup).
func test_rename_sets_node_name() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var leaf := st._resolve(root, "Branch/Leaf")
	leaf.name = "Renamed"
	assert_eq(str(leaf.name), "Renamed")
	root.free()

# Review fix (PR #5): move_node must preserve a node's existing owner when that owner
# is still a valid ancestor after the move, and only fall back to root otherwise.
func test_move_owner_preserves_valid_owner() -> void:
	var st = SceneTools.new()
	var root := _make_tree()
	var branch := st._resolve(root, "Branch")
	var leaf := st._resolve(root, "Branch/Leaf")
	# Owner == root, moving Leaf under Child (still under root) -> root stays the owner.
	var child := st._resolve(root, "Child")
	assert_eq(st._move_owner(root, child, root), root)
	# Owner is an ancestor of the new parent -> preserved (Branch owns, move under Branch).
	assert_eq(st._move_owner(branch, branch, root), branch)
	# Ownerless node -> falls back to root so it still serializes.
	assert_eq(st._move_owner(null, child, root), root)
	# Owner that is NOT an ancestor of the new parent -> falls back to root.
	assert_eq(st._move_owner(leaf, child, root), root)
	root.free()

# Review fix (PR #5): duplicate_node must reject a copy that silently lost a script.
func test_scripts_preserved_detects_dropped_script() -> void:
	var st = SceneTools.new()
	var s := GDScript.new()
	s.source_code = "extends Node"
	s.reload()
	var orig := Node.new()
	orig.set_script(s)
	var dup := Node.new()  # the "duplicate" lost the script
	assert_false(st._scripts_preserved(orig, dup))
	# A faithful copy (same script on both) passes.
	var dup2 := Node.new()
	dup2.set_script(s)
	assert_true(st._scripts_preserved(orig, dup2))
	# Scriptless on both sides is fine.
	var bare_a := Node.new()
	var bare_b := Node.new()
	assert_true(st._scripts_preserved(bare_a, bare_b))
	orig.free(); dup.free(); dup2.free(); bare_a.free(); bare_b.free()

# Review fix (PR #5): a child-count mismatch in the subtree also fails the check.
func test_scripts_preserved_checks_subtree_shape() -> void:
	var st = SceneTools.new()
	var orig := Node.new()
	orig.add_child(Node.new())
	var dup := Node.new()  # no children
	assert_false(st._scripts_preserved(orig, dup))
	orig.free(); dup.free()
