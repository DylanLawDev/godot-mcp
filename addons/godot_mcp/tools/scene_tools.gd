@tool
extends RefCounted

const _NO_SCENE := "No scene is currently open"

# --- Public tools ---

func get_scene_tree(_args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	return {"ok": true, "value": {"tree": _serialize_tree(root, root)}}

func get_node_properties(_args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	return {"ok": false, "error": "not implemented"}

func create_node(_args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	return {"ok": false, "error": "not implemented"}

func delete_node(_args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	return {"ok": false, "error": "not implemented"}

func modify_node(_args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	return {"ok": false, "error": "not implemented"}

# --- Pure helpers ---

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
