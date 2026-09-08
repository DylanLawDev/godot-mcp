@tool
extends RefCounted

# Shared, editor-agnostic node helpers. Used by BOTH the editor scene tools
# (tools/scene_tools.gd) and the runtime scenario engine
# (runtime/scenario_engine.gd) so the subtle type-coercion logic has one home.
# Every function takes its target node(s) explicitly; nothing here touches
# EditorInterface or UndoRedo.

# Map a root-relative NodePath string to a Node (or null). "." -> root.
# Rejects absolute paths (/root/...) and any path that resolves outside the
# root subtree (e.g. "..").
static func resolve(root: Node, path: String) -> Node:
	if path == "" or path == ".":
		return root
	if NodePath(path).is_absolute():
		return null
	var node := root.get_node_or_null(NodePath(path))
	if node == null or (node != root and not root.is_ancestor_of(node)):
		return null
	return node

# Instantiate a Node subclass by class name, or null if invalid / not a Node.
static func make_node(type: String, node_name: String) -> Node:
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

# Decode props into {valid: [{name, value}], errors: [{name, error}]}.
# A name absent from the node's property list is an error; the rest decode via str_to_var.
static func decode_props(node: Node, props: Dictionary) -> Dictionary:
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
# (that raises a runtime error); allows int/float and String/StringName coercion.
# String/StringName matters for properties Godot stores as StringName (e.g. `name`):
# a String value applied to such a property reads back as StringName, which a strict
# typeof check would wrongly call "not applied".
static func value_applied(current, intended) -> bool:
	var tc := typeof(current)
	var ti := typeof(intended)
	if tc == ti:
		return current == intended
	if tc in [TYPE_INT, TYPE_FLOAT] and ti in [TYPE_INT, TYPE_FLOAT]:
		return float(current) == float(intended)
	if tc in [TYPE_STRING, TYPE_STRING_NAME] and ti in [TYPE_STRING, TYPE_STRING_NAME]:
		return String(current) == String(intended)
	return false

# Set decoded values directly on the node, verifying each actually took.
# Returns {set:[names], errors:[{name,error}]}.
static func apply_props(node: Node, props: Dictionary) -> Dictionary:
	var decoded := decode_props(node, props)
	var done := []
	for item in decoded["valid"]:
		node.set(item["name"], item["value"])
		if value_applied(node.get(item["name"]), item["value"]):
			done.append(item["name"])
		else:
			decoded["errors"].append({"name": item["name"], "error": "Value not applied (type mismatch)"})
	return {"set": done, "errors": decoded["errors"]}

# All entries of get_property_list() except category/group/subgroup separators,
# each value encoded with var_to_str so it survives the JSON boundary.
static func encode_props(node: Node) -> Dictionary:
	var skip := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP
	var out := {}
	for p in node.get_property_list():
		if int(p["usage"]) & skip:
			continue
		var name: String = p["name"]
		out[name] = var_to_str(node.get(name))
	return out

# Recursively serialize `node`'s subtree. `path` is relative to `root` ("." for root).
static func serialize_tree(node: Node, root: Node) -> Dictionary:
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
		out["children"].append(serialize_tree(c, root))
	return out

# Bounded variant for runtime responses. Editor callers retain their full-tree API.
static func serialize_tree_bounded(node: Node, root: Node, max_depth: int, max_nodes: int) -> Dictionary:
	var budget := {"remaining": max_nodes, "truncated": false}
	var tree := _bounded_tree(node, root, max_depth, budget)
	return {"tree": tree, "truncated": budget.truncated}

static func _bounded_tree(node: Node, root: Node, depth: int, budget: Dictionary) -> Dictionary:
	budget.remaining -= 1
	var out := {"name": str(node.name), "type": node.get_class(), "path": str(root.get_path_to(node)), "script": null, "children": []}
	var script = node.get_script()
	if script != null and script.resource_path != "":
		out.script = script.resource_path
	if depth == 0:
		budget.truncated = budget.truncated or node.get_child_count() > 0
		return out
	for child in node.get_children():
		if budget.remaining <= 0:
			budget.truncated = true
			break
		out.children.append(_bounded_tree(child, root, depth - 1, budget))
	return out

static func encode_selected_props(node: Node, names: Array) -> Dictionary:
	var known := {}
	var skip := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP
	for property in node.get_property_list():
		if not (int(property.usage) & skip):
			known[property.name] = true
	# Validate all names before evaluating getters.
	for name in names:
		if not name is String or not known.has(name):
			return {"ok": false, "error": "Unknown runtime property: " + str(name)}
	var values := {}
	for name in names:
		values[name] = var_to_str(node.get(name))
	return {"ok": true, "value": values}
