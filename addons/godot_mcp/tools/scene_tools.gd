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
	var ur = _undo_redo()
	if ur == null:
		_attach(parent, node, root)
	else:
		ur.create_action("MCP: create node")
		ur.add_do_method(self, "_attach", parent, node, root)
		ur.add_do_reference(node)
		ur.add_undo_method(self, "_detach", parent, node)
		ur.commit_action()
	return {"ok": true, "value": {"path": str(root.get_path_to(node))}}

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
		ur.create_action("MCP: delete node")
		ur.add_do_method(self, "_detach", parent, node)
		ur.add_undo_method(self, "_attach", parent, node, root)
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

# --- Pure helpers ---

# Add `child` under `parent` and root it at `root` so it persists when the scene is saved.
func _attach(parent: Node, child: Node, root: Node) -> void:
	parent.add_child(child)
	child.owner = root

# Remove `child` from `parent` WITHOUT freeing it (the caller / undo history owns it).
func _detach(parent: Node, child: Node) -> void:
	parent.remove_child(child)

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
	return root.get_node_or_null(NodePath(path))

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
