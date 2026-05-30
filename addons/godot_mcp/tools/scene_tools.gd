@tool
extends RefCounted

const _NO_SCENE := "No scene is currently open"

# --- Public tools ---

func get_scene_tree(_args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	return {"ok": true, "value": {"tree": _serialize_tree(root, root)}}

func get_node_properties(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var path := str(args.get("path", ""))
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	return {"ok": true, "value": {
		"path": path,
		"type": node.get_class(),
		"properties": _encode_props(node),
	}}

func create_node(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var parent_path := str(args.get("parent_path", "."))
	var parent := _resolve(root, parent_path)
	if parent == null:
		return {"ok": false, "error": "Parent node not found: " + parent_path}
	var type := str(args.get("type", ""))
	var node := _make_node(type, str(args.get("name", type)))
	if node == null:
		return {"ok": false, "error": "Invalid node type: " + type}
	var props_arg = args.get("properties", {})
	if typeof(props_arg) != TYPE_DICTIONARY:
		return {"ok": false, "error": "'properties' must be an object"}
	var props: Dictionary = props_arg
	var ur = _undo_redo()
	var applied := {"set": [], "errors": []}
	if ur == null:
		_attach(parent, node, root)
		if not props.is_empty():
			applied = _apply_props(node, props)
	else:
		# Decode against the fresh instance so the property list is known before attach.
		var decoded := _decode_props(node, props)
		ur.create_action("MCP: create node")
		ur.add_do_method(self, "_attach", parent, node, root)
		ur.add_do_reference(node)
		for item in decoded["valid"]:
			ur.add_do_property(node, item["name"], item["value"])
		ur.add_undo_method(self, "_detach", parent, node)
		ur.commit_action()
		var done := []
		for item in decoded["valid"]:
			if _value_applied(node.get(item["name"]), item["value"]):
				done.append(item["name"])
			else:
				decoded["errors"].append({"name": item["name"], "error": "Value not applied (type mismatch)"})
		applied = {"set": done, "errors": decoded["errors"]}
	return {"ok": true, "value": {
		"path": str(root.get_path_to(node)),
		"set": applied["set"],
		"errors": applied["errors"],
	}}

func delete_node(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var path := str(args.get("path", ""))
	if path == "" or path == ".":
		return {"ok": false, "error": "Cannot delete the scene root"}
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	var parent := node.get_parent()
	var ur = _undo_redo()
	if ur == null:
		_detach(parent, node)
		node.free()
	else:
		var index := node.get_index()
		var owners := _capture_owners(node)
		ur.create_action("MCP: delete node")
		ur.add_do_method(self, "_detach", parent, node)
		ur.add_undo_method(self, "_restore", parent, node, index, owners)
		ur.add_undo_reference(node)
		ur.commit_action()
	return {"ok": true, "value": {"deleted": path}}

func modify_node(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var path := str(args.get("path", ""))
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	var props_arg = args.get("properties", {})
	if typeof(props_arg) != TYPE_DICTIONARY:
		return {"ok": false, "error": "'properties' must be an object"}
	var props: Dictionary = props_arg
	var ur = _undo_redo()
	if ur == null:
		var res := _apply_props(node, props)
		res["path"] = path
		return {"ok": true, "value": res}
	# Live editor: symmetric do/undo so BOTH undo and redo work; commit applies the do branch.
	var decoded := _decode_props(node, props)
	ur.create_action("MCP: modify node")
	for item in decoded["valid"]:
		ur.add_do_property(node, item["name"], item["value"])
		ur.add_undo_property(node, item["name"], node.get(item["name"]))
	ur.commit_action()
	var done := []
	for item in decoded["valid"]:
		if _value_applied(node.get(item["name"]), item["value"]):
			done.append(item["name"])
		else:
			decoded["errors"].append({"name": item["name"], "error": "Value not applied (type mismatch)"})
	return {"ok": true, "value": {"path": path, "set": done, "errors": decoded["errors"]}}

func duplicate_node(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var path := str(args.get("path", ""))
	if path == "" or path == ".":
		return {"ok": false, "error": "Cannot duplicate the scene root"}
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	var parent := node.get_parent()
	var dup: Node = node.duplicate()
	var new_name := str(args.get("new_name", ""))
	if new_name != "":
		dup.name = new_name
	var ur = _undo_redo()
	if ur == null:
		parent.add_child(dup)
		_set_owner_recursive(dup, root)
	else:
		ur.create_action("MCP: duplicate node")
		ur.add_do_method(parent, "add_child", dup)
		ur.add_do_method(self, "_set_owner_recursive", dup, root)
		ur.add_do_reference(dup)
		ur.add_undo_method(self, "_detach", parent, dup)
		ur.commit_action()
	return {"ok": true, "value": {"path": str(root.get_path_to(dup))}}

func move_node(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var path := str(args.get("path", ""))
	if path == "" or path == ".":
		return {"ok": false, "error": "Cannot move the scene root"}
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	var new_parent_path := str(args.get("new_parent_path", ""))
	var new_parent := _resolve(root, new_parent_path)
	if new_parent == null:
		return {"ok": false, "error": "New parent node not found: " + new_parent_path}
	if node == new_parent or node.is_ancestor_of(new_parent):
		return {"ok": false, "error": "Cannot move a node into itself or its own descendant"}
	var keep := bool(args.get("keep_global_transform", true))
	var old_parent := node.get_parent()
	var old_index := node.get_index()
	var ur = _undo_redo()
	if ur == null:
		node.reparent(new_parent, keep)
		node.owner = root
	else:
		ur.create_action("MCP: move node")
		ur.add_do_method(node, "reparent", new_parent, keep)
		ur.add_do_property(node, "owner", root)
		ur.add_undo_method(node, "reparent", old_parent, keep)
		ur.add_undo_method(old_parent, "move_child", node, old_index)
		ur.add_undo_property(node, "owner", root)
		ur.commit_action()
	return {"ok": true, "value": {"path": str(root.get_path_to(node))}}

func rename_node(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var path := str(args.get("path", ""))
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	var new_name := str(args.get("name", ""))
	if new_name.strip_edges() == "":
		return {"ok": false, "error": "Name must not be empty"}
	var old_name := str(node.name)
	var ur = _undo_redo()
	if ur == null:
		node.name = new_name
	else:
		ur.create_action("MCP: rename node")
		ur.add_do_property(node, "name", new_name)
		ur.add_undo_property(node, "name", old_name)
		ur.commit_action()
	# Godot may de-duplicate names, so report the actual resulting name.
	return {"ok": true, "value": {"path": str(root.get_path_to(node)), "name": str(node.name)}}

func get_signals(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var path := str(args.get("path", ""))
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	return {"ok": true, "value": {"path": path, "signals": _encode_signals(node, root)}}

func connect_signal(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var from_path := str(args.get("from_path", ""))
	var source := _resolve(root, from_path)
	if source == null:
		return {"ok": false, "error": "Node not found: " + from_path}
	var to_path := str(args.get("to_path", ""))
	var target := _resolve(root, to_path)
	if target == null:
		return {"ok": false, "error": "Node not found: " + to_path}
	var sig := str(args.get("signal", ""))
	if not source.has_signal(sig):
		return {"ok": false, "error": "No such signal: " + sig}
	var method := str(args.get("method", ""))
	if not target.has_method(method):
		return {"ok": false, "error": "No such method: " + method}
	var flags := int(args.get("flags", Object.CONNECT_PERSIST))
	var cb := Callable(target, method)
	if source.is_connected(sig, cb):
		return {"ok": false, "error": "Signal already connected: " + sig + " -> " + to_path + "." + method}
	var ur = _undo_redo()
	if ur == null:
		source.connect(sig, cb, flags)
	else:
		ur.create_action("MCP: connect signal")
		ur.add_do_method(source, "connect", sig, cb, flags)
		ur.add_undo_method(source, "disconnect", sig, cb)
		ur.commit_action()
	return {"ok": true, "value": {"from_path": from_path, "signal": sig, "to_path": to_path, "method": method, "flags": flags}}

func disconnect_signal(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var from_path := str(args.get("from_path", ""))
	var source := _resolve(root, from_path)
	if source == null:
		return {"ok": false, "error": "Node not found: " + from_path}
	var to_path := str(args.get("to_path", ""))
	var target := _resolve(root, to_path)
	if target == null:
		return {"ok": false, "error": "Node not found: " + to_path}
	var sig := str(args.get("signal", ""))
	var method := str(args.get("method", ""))
	var cb := Callable(target, method)
	if not source.has_signal(sig) or not source.is_connected(sig, cb):
		return {"ok": false, "error": "Signal not connected: " + sig + " -> " + to_path + "." + method}
	var ur = _undo_redo()
	if ur == null:
		source.disconnect(sig, cb)
	else:
		ur.create_action("MCP: disconnect signal")
		ur.add_do_method(source, "disconnect", sig, cb)
		ur.add_undo_method(source, "connect", sig, cb, Object.CONNECT_PERSIST)
		ur.commit_action()
	return {"ok": true, "value": {"from_path": from_path, "signal": sig, "to_path": to_path, "method": method}}

func get_node_groups(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var path := str(args.get("path", ""))
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	return {"ok": true, "value": {"path": path, "groups": _groups_as_strings(node)}}

func set_node_groups(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var path := str(args.get("path", ""))
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	var groups_arg = args.get("groups", null)
	if typeof(groups_arg) != TYPE_ARRAY:
		return {"ok": false, "error": "'groups' must be an array"}
	var desired := []
	for g in groups_arg:
		desired.append(str(g))
	var current := _groups_as_strings(node)
	var ur = _undo_redo()
	if ur == null:
		_set_groups(node, desired)
	else:
		ur.create_action("MCP: set node groups")
		ur.add_do_method(self, "_set_groups", node, desired)
		ur.add_undo_method(self, "_set_groups", node, current)
		ur.commit_action()
	return {"ok": true, "value": {"path": path, "groups": _groups_as_strings(node)}}

func find_nodes_in_group(args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	var group := str(args.get("group", ""))
	var out := []
	_find_in_group(root, root, group, out)
	return {"ok": true, "value": {"paths": out}}

# --- Pure helpers ---

# A node's groups as plain Strings (get_groups returns StringNames).
func _groups_as_strings(node: Node) -> Array:
	var out := []
	for g in node.get_groups():
		out.append(str(g))
	return out

# Replace `node`'s group membership with exactly `desired`, persistently. Removes
# any group not in `desired` and adds (persistently) any that is missing.
func _set_groups(node: Node, desired: Array) -> void:
	var diff := _group_diff(_groups_as_strings(node), desired)
	for g in diff["removed"]:
		node.remove_from_group(g)
	for g in diff["added"]:
		node.add_to_group(g, true)

# Compute {added, removed} string arrays moving from `current` to `desired`.
func _group_diff(current: Array, desired: Array) -> Dictionary:
	var added := []
	var removed := []
	for g in desired:
		if not current.has(g):
			added.append(g)
	for g in current:
		if not desired.has(g):
			removed.append(g)
	return {"added": added, "removed": removed}

# Walk `node`'s subtree, appending root-relative paths of nodes in `group` to `out`.
func _find_in_group(node: Node, root: Node, group: String, out: Array) -> void:
	if node.is_in_group(group):
		out.append(str(root.get_path_to(node)))
	for c in node.get_children():
		_find_in_group(c, root, group, out)

# Encode `node`'s signals with their current connections. A connection target that
# is the root or a descendant of root is reported as a root-relative path; anything
# else (an outside object) is reported by its class name.
func _encode_signals(node: Node, root: Node) -> Array:
	var out := []
	for sig in node.get_signal_list():
		var name: String = sig["name"]
		var conns := []
		for c in node.get_signal_connection_list(name):
			var callable: Callable = c["callable"]
			var target = callable.get_object()
			var target_path: String
			if target is Node and (target == root or root.is_ancestor_of(target)):
				target_path = str(root.get_path_to(target))
			elif target != null:
				target_path = (target as Object).get_class()
			else:
				target_path = ""
			conns.append({
				"target_path": target_path,
				"method": str(callable.get_method()),
				"flags": int(c["flags"]),
			})
		out.append({"name": name, "args": sig["args"], "connections": conns})
	return out


# Root `node` and its entire subtree at `root` so a duplicated/moved subtree serializes.
func _set_owner_recursive(node: Node, root: Node) -> void:
	node.owner = root
	for c in node.get_children():
		_set_owner_recursive(c, root)

# Add `child` under `parent` and root it at `root` so it persists when the scene is saved.
func _attach(parent: Node, child: Node, root: Node) -> void:
	parent.add_child(child)
	child.owner = root

# Remove `child` from `parent` WITHOUT freeing it (the caller / undo history owns it).
func _detach(parent: Node, child: Node) -> void:
	parent.remove_child(child)

# Snapshot {node, owner} for `node` and every descendant, taken before a delete so
# the undo can restore subtree ownership (Godot clears owner when a node leaves the
# tree, which would otherwise drop ownerless grandchildren on the next save).
func _capture_owners(node: Node) -> Array:
	var out := [{"node": node, "owner": node.owner}]
	for c in node.get_children():
		out.append_array(_capture_owners(c))
	return out

# Undo of a delete: re-insert `node` under `parent` at its original sibling `index`
# and restore every captured owner across the subtree.
func _restore(parent: Node, node: Node, index: int, owners: Array) -> void:
	parent.add_child(node)
	parent.move_child(node, index)
	for e in owners:
		e["node"].owner = e["owner"]

# Decode props into {valid: [{name, value}], errors: [{name, error}]}.
# A name absent from the node's property list is an error; the rest decode via str_to_var.
func _decode_props(node: Node, props: Dictionary) -> Dictionary:
	var known := {}
	for p in node.get_property_list():
		known[p["name"]] = true
	var valid := []
	var errors := []
	for name in props.keys():
		if not known.has(name):
			errors.append({"name": name, "error": "No such property"})
			continue
		valid.append({"name": name, "value": str_to_var(str(props[name]))})
	return {"valid": valid, "errors": errors}

# Type-safe "did the set take?" check. Never compares mismatched Variant types with ==
# (that raises a runtime error); allows int/float coercion.
func _value_applied(current, intended) -> bool:
	var tc := typeof(current)
	var ti := typeof(intended)
	if tc == ti:
		return current == intended
	if tc in [TYPE_INT, TYPE_FLOAT] and ti in [TYPE_INT, TYPE_FLOAT]:
		return float(current) == float(intended)
	return false

# Set decoded values directly on the node, verifying each actually took.
# Returns {set:[names], errors:[{name,error}]}. (Headless / no-undo path.)
func _apply_props(node: Node, props: Dictionary) -> Dictionary:
	var decoded := _decode_props(node, props)
	var done := []
	for item in decoded["valid"]:
		node.set(item["name"], item["value"])
		if _value_applied(node.get(item["name"]), item["value"]):
			done.append(item["name"])
		else:
			decoded["errors"].append({"name": item["name"], "error": "Value not applied (type mismatch)"})
	return {"set": done, "errors": decoded["errors"]}

# Instantiate a Node subclass by class name, or null if invalid / not a Node.
func _make_node(type: String, node_name: String) -> Node:
	if not ClassDB.class_exists(type) or not ClassDB.can_instantiate(type):
		return null
	if not ClassDB.is_parent_class(type, "Node"):
		return null
	var inst = ClassDB.instantiate(type)
	if not (inst is Node):
		return null
	var n: Node = inst
	if node_name != "":
		n.name = node_name
	return n

# Map a root-relative NodePath string to a Node (or null). "." -> root.
func _resolve(root: Node, path: String) -> Node:
	if path == "" or path == ".":
		return root
	# Reject paths that escape the edited scene: absolute paths (/root/...) and
	# any path (e.g. "..") that resolves to a node outside the scene subtree.
	if NodePath(path).is_absolute():
		return null
	var node := root.get_node_or_null(NodePath(path))
	if node == null or (node != root and not root.is_ancestor_of(node)):
		return null
	return node

# All entries of get_property_list() except category/group/subgroup separators,
# each value encoded with var_to_str so it survives the JSON boundary.
func _encode_props(node: Node) -> Dictionary:
	var skip := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP
	var out := {}
	for p in node.get_property_list():
		if int(p["usage"]) & skip:
			continue
		var name: String = p["name"]
		out[name] = var_to_str(node.get(name))
	return out

# Recursively serialize `node`'s subtree. `path` is relative to `root` ("." for root).
func _serialize_tree(node: Node, root: Node) -> Dictionary:
	var out := {
		"name": str(node.name),
		"type": node.get_class(),
		"path": str(root.get_path_to(node)),
		"script": null,
		"children": [],
	}
	var scr = node.get_script()
	if scr != null and scr.resource_path != "":
		out["script"] = scr.resource_path
	for c in node.get_children():
		out["children"].append(_serialize_tree(c, root))
	return out

# --- Resource handlers ---

func scene_current(_args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": true, "value": {"open": false}}
	return {"ok": true, "value": {
		"path": root.scene_file_path,
		"tree": _serialize_tree(root, root),
	}}

func script_current(_args: Dictionary) -> Dictionary:
	var scr = _current_script()
	if scr == null:
		return {"ok": true, "value": {"open": false}}
	return {"ok": true, "value": {
		"path": scr.resource_path,
		"content": scr.source_code,
	}}

# --- Live seams (only meaningful inside a live editor; null headlessly) ---

func _edited_scene_root() -> Node:
	if not Engine.has_meta("GodotMCPPlugin"):
		return null
	var plugin = Engine.get_meta("GodotMCPPlugin")
	return plugin.get_editor_interface().get_edited_scene_root()

func _undo_redo():
	if not Engine.has_meta("GodotMCPPlugin"):
		return null
	var plugin = Engine.get_meta("GodotMCPPlugin")
	return plugin.get_undo_redo()

func _current_script():
	if not Engine.has_meta("GodotMCPPlugin"):
		return null
	var plugin = Engine.get_meta("GodotMCPPlugin")
	var se = plugin.get_editor_interface().get_script_editor()
	if se == null:
		return null
	return se.get_current_script()
