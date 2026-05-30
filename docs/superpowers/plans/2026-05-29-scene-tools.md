# Scene Tools & "current" Resources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add live scene-tree introspection + node CRUD (`get_scene_tree`, `get_node_properties`, `create_node`, `delete_node`, `modify_node`) and the `godot://scene/current` + `godot://script/current` MCP resources to the Godot MCP editor plugin.

**Architecture:** A new `tools/scene_tools.gd` (`@tool extends RefCounted`) splits *editor-state acquisition* (thin, live-only seams `_edited_scene_root()` / `_undo_redo()` that no-op headlessly, mirroring `_rescan_filesystem()`) from *pure node logic* (serialize / resolve / encode-props / mutation primitives) that is fully unit-tested by building real `Node` trees in-process. Live mutations are wrapped in `EditorUndoRedoManager` actions; the do/undo callables are the same pure primitives the tests call directly. Property values cross the JSON boundary via `var_to_str`/`str_to_var`.

**Tech Stack:** Pure GDScript, Godot 4.6.x, headless `SceneTree`-based test harness (`tests/test_case.gd`).

---

## File Structure

- **Create** `addons/godot_mcp/tools/scene_tools.gd` — all five tool handlers, the live seams, and the pure helpers. One responsibility: scene-tree introspection + node CRUD against the current edited scene.
- **Create** `addons/godot_mcp/tests/test_scene_tools.gd` — unit tests for pure helpers + guard paths.
- **Modify** `addons/godot_mcp/mcp_handler.gd` — construct a shared `SceneTools`, register 5 tools in `_build_default_registry`, register 2 resources in `_build_default_resource_registry`.
- **Modify** `addons/godot_mcp/tests/test_mcp_handler.gd` — wiring assertions (tools/list, resources/list, resources/read).
- **Modify** `README.md` and `docs/E2E_TESTING.md` — doc the new tools/resources + manual live-editor E2E steps.

### Contract reminders (match existing code exactly)

- Tool/resource handlers take `(args: Dictionary)` and return `{"ok": true, "value": <any>}` or `{"ok": false, "error": String}`.
- Node addressing: a `NodePath` **relative to the scene root**; the root is `"."`.
- Live seam guard: when `_edited_scene_root()` is `null`, every tool returns `{"ok": false, "error": "No scene is currently open"}`.
- Tests subclass `extends "res://addons/godot_mcp/tests/test_case.gd"`, name methods `test_*`, and use `assert_true/assert_false/assert_eq/assert_ne/assert_has`. Free any `Node` you create (`node.free()` frees its children too) so output stays pristine (no orphan warnings).

---

## Task 1: Skeleton + live seams + guard paths

**Files:**
- Create: `addons/godot_mcp/tools/scene_tools.gd`
- Test: `addons/godot_mcp/tests/test_scene_tools.gd`

- [ ] **Step 1: Write the failing guard tests**

Create `addons/godot_mcp/tests/test_scene_tools.gd`:

```gdscript
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Expected: FAIL — `scene_tools.gd` does not exist / parse error (cannot preload).

- [ ] **Step 3: Write minimal implementation**

Create `addons/godot_mcp/tools/scene_tools.gd`:

```gdscript
@tool
extends RefCounted

const _NO_SCENE := "No scene is currently open"

# --- Public tools ---

func get_scene_tree(_args: Dictionary) -> Dictionary:
	var root := _edited_scene_root()
	if root == null:
		return {"ok": false, "error": _NO_SCENE}
	return {"ok": false, "error": "not implemented"}

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Expected: PASS — `5 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/tools/scene_tools.gd addons/godot_mcp/tests/test_scene_tools.gd
git commit -m "feat: scene_tools skeleton with live seams and no-scene guards"
```

---

## Task 2: Serialize the scene tree (`_serialize_tree` + `get_scene_tree`)

**Files:**
- Modify: `addons/godot_mcp/tools/scene_tools.gd`
- Test: `addons/godot_mcp/tests/test_scene_tools.gd`

- [ ] **Step 1: Write the failing test**

Append to `test_scene_tools.gd`:

```gdscript
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Expected: FAIL — `_serialize_tree` not declared.

- [ ] **Step 3: Write minimal implementation**

In `scene_tools.gd`, replace the `get_scene_tree` body's `not implemented` return with:

```gdscript
	return {"ok": true, "value": {"tree": _serialize_tree(root, root)}}
```

And add this pure helper (in a `# --- Pure helpers ---` section above the seams):

```gdscript
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/tools/scene_tools.gd addons/godot_mcp/tests/test_scene_tools.gd
git commit -m "feat: serialize scene tree for get_scene_tree"
```

---

## Task 3: Resolve nodes + read properties (`_resolve`, `_encode_props`, `get_node_properties`)

**Files:**
- Modify: `addons/godot_mcp/tools/scene_tools.gd`
- Test: `addons/godot_mcp/tests/test_scene_tools.gd`

- [ ] **Step 1: Write the failing test**

Append to `test_scene_tools.gd`:

```gdscript
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Expected: FAIL — `_resolve` / `_encode_props` not declared.

- [ ] **Step 3: Write minimal implementation**

In `scene_tools.gd`, replace `get_node_properties`'s `not implemented` return with:

```gdscript
	var path := str(args.get("path", ""))
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	return {"ok": true, "value": {
		"path": path,
		"type": node.get_class(),
		"properties": _encode_props(node),
	}}
```

Add the pure helpers:

```gdscript
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/tools/scene_tools.gd addons/godot_mcp/tests/test_scene_tools.gd
git commit -m "feat: node resolution and property encoding for get_node_properties"
```

---

## Task 4: Mutation primitives + create/delete/modify wiring

**Files:**
- Modify: `addons/godot_mcp/tools/scene_tools.gd`
- Test: `addons/godot_mcp/tests/test_scene_tools.gd`

The pure primitives (`_attach`, `_detach`, `_apply_props`) are unit-tested directly. The public
`create_node`/`delete_node`/`modify_node` resolve targets, then in a live editor wrap the primitives
in an `EditorUndoRedoManager` action; when `_undo_redo()` is null (headless/fallback) they invoke the
primitive directly so behavior is identical without undo history.

- [ ] **Step 1: Write the failing test**

Append to `test_scene_tools.gd`:

```gdscript
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Expected: FAIL — `_attach` / `_detach` / `_apply_props` / `_make_node` not declared.

- [ ] **Step 3: Write minimal implementation**

In `scene_tools.gd`, add the pure primitives:

```gdscript
# Add `child` under `parent` and root it at `root` so it persists when the scene is saved.
func _attach(parent: Node, child: Node, root: Node) -> void:
	parent.add_child(child)
	child.owner = root

# Remove `child` from `parent` WITHOUT freeing it (the caller / undo history owns it).
func _detach(parent: Node, child: Node) -> void:
	parent.remove_child(child)

# Decode each value with str_to_var and set it. Returns {set:[names], errors:[{name,error}]}.
func _apply_props(node: Node, props: Dictionary) -> Dictionary:
	var valid := {}
	for p in node.get_property_list():
		valid[p["name"]] = true
	var done := []
	var errors := []
	for name in props.keys():
		if not valid.has(name):
			errors.append({"name": name, "error": "No such property"})
			continue
		node.set(name, str_to_var(str(props[name])))
		done.append(name)
	return {"set": done, "errors": errors}

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
```

Replace `create_node`'s `not implemented` return:

```gdscript
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
```

Replace `delete_node`'s `not implemented` return:

```gdscript
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
```

Replace `modify_node`'s `not implemented` return:

```gdscript
	var path := str(args.get("path", ""))
	var node := _resolve(root, path)
	if node == null:
		return {"ok": false, "error": "Node not found: " + path}
	var props: Dictionary = args.get("properties", {})
	var ur = _undo_redo()
	if ur != null:
		ur.create_action("MCP: modify node")
		for name in props.keys():
			ur.add_undo_property(node, name, node.get(name))
		ur.commit_action()  # snapshot only; values applied below
	var res := _apply_props(node, props)
	res["path"] = path
	return {"ok": true, "value": res}
```

> Note on `modify_node` undo: the undo snapshot of current values is registered before applying. Applying via `_apply_props` (rather than `add_do_property`) keeps a single decode/validation path shared with the tests; the editor still records the prior values for Ctrl-Z. This is acceptable for v1.

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Expected: PASS.

- [ ] **Step 5: Run the full suite (regression)**

Run: `./addons/godot_mcp/run_tests.sh`
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
git add addons/godot_mcp/tools/scene_tools.gd addons/godot_mcp/tests/test_scene_tools.gd
git commit -m "feat: node create/delete/modify primitives with undo-redo wiring"
```

---

## Task 5: Register the 5 tools in the handler

**Files:**
- Modify: `addons/godot_mcp/mcp_handler.gd`
- Test: `addons/godot_mcp/tests/test_mcp_handler.gd`

- [ ] **Step 1: Write the failing test**

Append to `test_mcp_handler.gd`:

```gdscript
func test_tools_list_includes_scene_tools() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":20,"method":"tools/list","params":{}}'))
	var names := []
	for t in d["result"]["tools"]:
		names.append(t["name"])
	for expected in ["get_scene_tree", "get_node_properties", "create_node", "delete_node", "modify_node"]:
		assert_has(names, expected)

func test_tools_call_get_scene_tree_reports_no_scene_headless() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"get_scene_tree","arguments":{}}}'))
	assert_true(d["result"]["isError"])
	assert_eq(d["result"]["content"][0]["text"], "No scene is currently open")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_mcp_handler.gd`
Expected: FAIL — scene tool names absent from `tools/list`.

- [ ] **Step 3: Write minimal implementation**

In `mcp_handler.gd`:

Add the preload near the other tool consts (after the `ProjectTools` line):

```gdscript
const SceneTools = preload("res://addons/godot_mcp/tools/scene_tools.gd")
```

In `_init`, construct a shared scene instance and pass it to both builders:

```gdscript
func _init(registry = null, resources = null) -> void:
	var project = ProjectTools.new()
	var scene = SceneTools.new()
	_registry = registry if registry != null else _build_default_registry(project, scene)
	_resources = resources if resources != null else _build_default_resource_registry(project, scene)
```

Change `_build_default_registry`'s signature and add registrations before the `set_meta` calls:

```gdscript
func _build_default_registry(project = null, scene = null):
```

```gdscript
	if scene == null:
		scene = SceneTools.new()
	reg.register("get_scene_tree", "Get the current edited scene's node tree. No args.",
		{"type": "object", "properties": {}},
		Callable(scene, "get_scene_tree"))
	reg.register("get_node_properties", "Get a node's properties. Args: {path} (NodePath relative to scene root; '.' = root).",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(scene, "get_node_properties"))
	reg.register("create_node", "Create a node under a parent. Args: {parent_path, type, name?}.",
		{"type": "object", "properties": {"parent_path": {"type": "string"}, "type": {"type": "string"}, "name": {"type": "string"}}, "required": ["parent_path", "type"]},
		Callable(scene, "create_node"))
	reg.register("delete_node", "Delete a node. Args: {path}.",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(scene, "delete_node"))
	reg.register("modify_node", "Set node properties (values are Godot var_to_str strings). Args: {path, properties}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "properties": {"type": "object"}}, "required": ["path", "properties"]},
		Callable(scene, "modify_node"))
	reg.set_meta("_scene", scene)
```

(Keep the existing `set_meta("_project"/"_files"/"_scripts")` lines.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_mcp_handler.gd`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/mcp_handler.gd addons/godot_mcp/tests/test_mcp_handler.gd
git commit -m "feat: register scene tools in mcp_handler"
```

---

## Task 6: Register the two "current" resources

**Files:**
- Modify: `addons/godot_mcp/tools/scene_tools.gd` (add resource handlers)
- Modify: `addons/godot_mcp/mcp_handler.gd` (`_build_default_resource_registry`)
- Test: `addons/godot_mcp/tests/test_scene_tools.gd`, `addons/godot_mcp/tests/test_mcp_handler.gd`

- [ ] **Step 1: Write the failing tests**

Append to `test_scene_tools.gd` (headless: nothing open → `{open:false}`, not an error):

```gdscript
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
```

Append to `test_mcp_handler.gd`:

```gdscript
func test_resources_list_includes_current_scene_and_script() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":22,"method":"resources/list","params":{}}'))
	var uris := []
	for r in d["result"]["resources"]:
		uris.append(r["uri"])
	assert_has(uris, "godot://scene/current")
	assert_has(uris, "godot://script/current")

func test_resources_read_scene_current_closed_headless() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":23,"method":"resources/read","params":{"uri":"godot://scene/current"}}'))
	var c = d["result"]["contents"][0]
	assert_eq(c["uri"], "godot://scene/current")
	assert_eq(c["mimeType"], "application/json")
	var body = JSON.parse_string(c["text"])
	assert_eq(body["open"], false)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Then: `godot4 --headless --path . --script addons/godot_mcp/tests/test_mcp_handler.gd`
Expected: FAIL — `scene_current`/`script_current` not declared; resource URIs absent.

- [ ] **Step 3: Write minimal implementation**

In `scene_tools.gd`, add the resource handlers (they use the same `{ok, value}` contract):

```gdscript
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
	var scr := _current_script()
	if scr == null:
		return {"ok": true, "value": {"open": false}}
	return {"ok": true, "value": {
		"path": scr.resource_path,
		"content": scr.source_code,
	}}

func _current_script():
	if not Engine.has_meta("GodotMCPPlugin"):
		return null
	var plugin = Engine.get_meta("GodotMCPPlugin")
	var se = plugin.get_editor_interface().get_script_editor()
	if se == null:
		return null
	return se.get_current_script()
```

In `mcp_handler.gd`, change `_build_default_resource_registry`'s signature and register the two resources:

```gdscript
func _build_default_resource_registry(project = null, scene = null):
```

After the existing `godot://project/info` registration and before its `set_meta`:

```gdscript
	if scene == null:
		scene = SceneTools.new()
	rreg.register("godot://scene/current", "scene_current",
		"The currently open scene (path + node tree).", "application/json",
		Callable(scene, "scene_current"))
	rreg.register("godot://script/current", "script_current",
		"The currently open script (path + source).", "application/json",
		Callable(scene, "script_current"))
	rreg.set_meta("_scene", scene)
```

(Keep the existing `rreg.set_meta("_project", project)` line.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Then: `godot4 --headless --path . --script addons/godot_mcp/tests/test_mcp_handler.gd`
Expected: PASS for both.

- [ ] **Step 5: Run the full suite**

Run: `./addons/godot_mcp/run_tests.sh`
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
git add addons/godot_mcp/tools/scene_tools.gd addons/godot_mcp/mcp_handler.gd addons/godot_mcp/tests/test_scene_tools.gd addons/godot_mcp/tests/test_mcp_handler.gd
git commit -m "feat: add godot://scene/current and godot://script/current resources"
```

---

## Task 7: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/E2E_TESTING.md`
- Modify: `CLAUDE.md` (update the v1 scope/tool count line)

- [ ] **Step 1: Update README tool list**

Add the 5 new tools and 2 new resources to the README's tool/resource tables (match the existing
table format). Tools: `get_scene_tree`, `get_node_properties`, `create_node`, `delete_node`,
`modify_node`. Resources: `godot://scene/current`, `godot://script/current`. Note that scene tools
require a scene open in the editor and mutations are undoable.

- [ ] **Step 2: Update `docs/E2E_TESTING.md`**

Add a manual live-editor section: open `examples/scenes/main.tscn` in the editor, then via Claude:
`get_scene_tree`, `create_node` (verify it appears in the Scene dock and Ctrl-Z removes it),
`modify_node` to set a `Node2D` `position`, `delete_node`, and read `godot://scene/current` /
`godot://script/current` (open `examples/scripts/player.gd` first).

- [ ] **Step 3: Update `CLAUDE.md` scope line**

In the `## Scope` section, update the tool count and list to include the 5 scene tools, and add
`godot://scene/current` + `godot://script/current` to the resource layer description.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/E2E_TESTING.md CLAUDE.md
git commit -m "docs: document scene tools and current resources"
```

---

## Self-Review notes

- **Spec coverage:** 5 tools (Tasks 2–5), 2 resources (Task 6), `var_to_str`/`str_to_var` (Tasks 3–4),
  full `get_property_list()` minus separators (Task 3), `EditorUndoRedoManager` mutations (Task 4),
  headless guards + `{open:false}` resource bodies (Tasks 1, 6), wiring + handler tests (Tasks 5–6),
  docs/E2E (Task 7). All spec sections map to a task.
- **Type consistency:** helper names are stable across tasks — `_serialize_tree(node, root)`,
  `_resolve(root, path)`, `_encode_props(node)`, `_attach(parent, child, root)`, `_detach(parent, child)`,
  `_apply_props(node, props)`, `_make_node(type, name)`, `_edited_scene_root()`, `_undo_redo()`,
  `_current_script()`, resource handlers `scene_current`/`script_current`.
- **Note for implementer:** `docs/superpowers/` is gitignored in this repo — the doc commits in Task 7
  touch only tracked files (`README.md`, `docs/E2E_TESTING.md`, `CLAUDE.md`).
