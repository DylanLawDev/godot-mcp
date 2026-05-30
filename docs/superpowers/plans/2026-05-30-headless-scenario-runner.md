# Headless Scenario Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Claude launch a headless Godot process that runs a real scene, drives it with input-map actions, manipulates/inspects runtime nodes, and emits a machine-readable pass/fail JSON verdict.

**Architecture:** A `--script` `SceneTree` main loop (`scenario_runner.gd`) loads a scenario JSON, instances the target scene, and pumps physics frames while delegating each step to a frame-agnostic `scenario_engine.gd` (`RefCounted`). The engine and the editor's `scene_tools.gd` share one extracted `utils/node_ops.gd` for node resolution and type-safe property coercion. Results are written to a JSON file Claude reads via Bash; the engine carries no editor or HTTP dependency.

**Tech Stack:** Pure GDScript, Godot 4.6.x, headless. Tests subclass `addons/godot_mcp/tests/test_case.gd` and run via `addons/godot_mcp/run_tests.sh`.

---

## File Structure

- **Create** `addons/godot_mcp/utils/node_ops.gd` — shared static node helpers (resolve, serialize_tree, encode/decode/apply props, value_applied, make_node). One source of truth, no editor coupling.
- **Modify** `addons/godot_mcp/tools/scene_tools.gd` — its private `_resolve/_serialize_tree/_encode_props/_decode_props/_apply_props/_value_applied/_make_node` become one-line delegators to `NodeOps`. Behavior-preserving.
- **Create** `addons/godot_mcp/runtime/scenario_engine.gd` — frame-agnostic step executor; owns the scene root, accumulates step outcomes, assertion verdicts, signal counters.
- **Create** `addons/godot_mcp/runtime/scenario_runner.gd` — `SceneTree` main loop: CLI parse, scenario load/validate, scene instance, frame pump, log capture, results write, exit code.
- **Create** `addons/godot_mcp/runtime/run_scenario.sh` — one-line launch wrapper (mirrors `run_tests.sh`, honors `$GODOT`).
- **Create** `addons/godot_mcp/tests/test_node_ops.gd` — direct coverage of the extracted helpers.
- **Create** `addons/godot_mcp/tests/test_scenario_engine.gd` — drives the engine on in-memory scenes (no process launch).
- **Create** `examples/scripts/runner_demo.gd`, `examples/scenes/runner_demo.tscn`, `examples/scenarios/move_right.json` — manual E2E fixture.
- **Modify** `docs/E2E_TESTING.md`, `README.md`, `CLAUDE.md` — document the runner.

---

## Task 1: Extract `node_ops.gd` and refactor `scene_tools.gd`

**Files:**
- Create: `addons/godot_mcp/utils/node_ops.gd`
- Create: `addons/godot_mcp/tests/test_node_ops.gd`
- Modify: `addons/godot_mcp/tools/scene_tools.gd` (top of file + 7 helper bodies)

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_node_ops.gd`:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const NodeOps = preload("res://addons/godot_mcp/utils/node_ops.gd")

func test_resolve_root_and_child() -> void:
	var root := Node.new()
	root.name = "Root"
	var child := Node.new()
	child.name = "Child"
	root.add_child(child)
	assert_eq(NodeOps.resolve(root, "."), root)
	assert_eq(NodeOps.resolve(root, "Child"), child)
	assert_eq(NodeOps.resolve(root, "Missing"), null)
	# Absolute paths and traversal outside the subtree are rejected.
	assert_eq(NodeOps.resolve(root, "/root/Child"), null)
	root.free()

func test_make_node() -> void:
	var n := NodeOps.make_node("Node2D", "Foo")
	assert_true(n is Node2D)
	assert_eq(str(n.name), "Foo")
	n.free()
	assert_eq(NodeOps.make_node("NotARealClass", "x"), null)
	# A non-Node class is rejected.
	assert_eq(NodeOps.make_node("RefCounted", "x"), null)

func test_value_applied_coercion() -> void:
	assert_true(NodeOps.value_applied(1, 1.0))   # int/float coercion
	assert_true(NodeOps.value_applied("a", "a"))
	assert_false(NodeOps.value_applied("a", 1))   # mismatched types never crash

func test_apply_props_sets_and_reports() -> void:
	var n := Node2D.new()
	var res := NodeOps.apply_props(n, {"position": "Vector2(5, 6)"})
	assert_has(res["set"], "position")
	assert_eq(n.position, Vector2(5, 6))
	# Unknown property is reported, not applied.
	var res2 := NodeOps.apply_props(n, {"no_such_prop": "1"})
	assert_eq(res2["set"].size(), 0)
	assert_eq(res2["errors"].size(), 1)
	n.free()

func test_serialize_tree_shape() -> void:
	var root := Node.new()
	root.name = "Root"
	var child := Node2D.new()
	child.name = "Kid"
	root.add_child(child)
	var tree := NodeOps.serialize_tree(root, root)
	assert_eq(tree["name"], "Root")
	assert_eq(tree["path"], ".")
	assert_eq(tree["children"].size(), 1)
	assert_eq(tree["children"][0]["name"], "Kid")
	root.free()

func test_encode_props_returns_strings() -> void:
	var n := Node2D.new()
	n.name = "N"
	var props := NodeOps.encode_props(n)
	assert_true(props.has("position"))
	assert_eq(typeof(props["position"]), TYPE_STRING)
	n.free()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_node_ops.gd`
Expected: FAIL — `Could not load script ... node_ops.gd` / preload resolves to null.

- [ ] **Step 3: Create `node_ops.gd`**

Create `addons/godot_mcp/utils/node_ops.gd` (bodies copied verbatim from `scene_tools.gd`'s current private helpers, de-underscored, made `static`):

```gdscript
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
# (that raises a runtime error); allows int/float coercion.
static func value_applied(current, intended) -> bool:
	var tc := typeof(current)
	var ti := typeof(intended)
	if tc == ti:
		return current == intended
	if tc in [TYPE_INT, TYPE_FLOAT] and ti in [TYPE_INT, TYPE_FLOAT]:
		return float(current) == float(intended)
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_node_ops.gd`
Expected: PASS — `=== 6 passed, 0 failed (test_node_ops.gd) ===`

- [ ] **Step 5: Refactor `scene_tools.gd` to delegate**

At the top of `addons/godot_mcp/tools/scene_tools.gd`, after the existing `const Paths = preload(...)` line, add:

```gdscript
const NodeOps = preload("res://addons/godot_mcp/utils/node_ops.gd")
```

Replace the **bodies** of these seven existing private methods (keep their signatures and the `# --- Live seams ---`/other surrounding code exactly as is) with delegators:

```gdscript
func _resolve(root: Node, path: String) -> Node:
	return NodeOps.resolve(root, path)

func _make_node(type: String, node_name: String) -> Node:
	return NodeOps.make_node(type, node_name)

func _decode_props(node: Node, props: Dictionary) -> Dictionary:
	return NodeOps.decode_props(node, props)

func _value_applied(current, intended) -> bool:
	return NodeOps.value_applied(current, intended)

func _apply_props(node: Node, props: Dictionary) -> Dictionary:
	return NodeOps.apply_props(node, props)

func _encode_props(node: Node) -> Dictionary:
	return NodeOps.encode_props(node)

func _serialize_tree(node: Node, root: Node) -> Dictionary:
	return NodeOps.serialize_tree(node, root)
```

- [ ] **Step 6: Run the scene-tools suite to confirm the refactor is behavior-preserving**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
Expected: PASS — same pass count as before the change, 0 failed.

- [ ] **Step 7: Commit**

```bash
git add addons/godot_mcp/utils/node_ops.gd addons/godot_mcp/tests/test_node_ops.gd addons/godot_mcp/tools/scene_tools.gd
git commit -m "refactor: extract shared node_ops helpers from scene_tools"
```

---

## Task 2: Scenario engine — core + non-assert steps

**Files:**
- Create: `addons/godot_mcp/runtime/scenario_engine.gd`
- Create: `addons/godot_mcp/tests/test_scenario_engine.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_scenario_engine.gd`:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const ScenarioEngine = preload("res://addons/godot_mcp/runtime/scenario_engine.gd")

# Build a small Node2D root with a named child for path-based steps.
func _make_root() -> Node:
	var root := Node2D.new()
	root.name = "Root"
	var child := Node2D.new()
	child.name = "Sub"
	root.add_child(child)
	return root

func test_set_property_step() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var res := eng.execute({"type": "set_property", "path": "Sub", "properties": {"position": "Vector2(10, 0)"}})
	assert_true(res["ok"])
	assert_eq(root.get_node("Sub").position, Vector2(10, 0))
	root.free()

func test_set_property_unknown_node_is_fatal() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var res := eng.execute({"type": "set_property", "path": "Nope", "properties": {}})
	assert_false(res["ok"])
	assert_true(res.get("fatal", false))
	root.free()

func test_create_and_delete_node() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var c := eng.execute({"type": "create_node", "parent_path": ".", "type": "Node", "name": "Made"})
	assert_true(c["ok"])
	assert_ne(root.get_node_or_null("Made"), null)
	var d := eng.execute({"type": "delete_node", "path": "Made"})
	assert_true(d["ok"])
	root.free()

func test_delete_root_rejected() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_false(eng.execute({"type": "delete_node", "path": "."})["ok"])
	root.free()

func test_call_method_captures_return() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	# Node2D.get_position_delta has no args; use a no-arg method with a known return.
	var res := eng.execute({"type": "call_method", "path": "Sub", "method": "get_class"})
	assert_true(res["ok"])
	assert_has(res["detail"], "Node2D")
	root.free()

func test_call_method_missing_is_fatal() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_false(eng.execute({"type": "call_method", "path": "Sub", "method": "no_such_method"})["ok"])
	root.free()

func test_wait_steps_return_frame_counts() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_eq(eng.execute({"type": "wait_frames", "count": 5})["frames"], 5)
	var fps := int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60))
	assert_eq(eng.execute({"type": "wait_seconds", "seconds": 1.0})["frames"], fps)
	root.free()

func test_unknown_step_type() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_false(eng.execute({"type": "bogus"})["ok"])
	root.free()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scenario_engine.gd`
Expected: FAIL — preload of `scenario_engine.gd` resolves to null.

- [ ] **Step 3: Create `scenario_engine.gd` with core + non-assert steps**

Create `addons/godot_mcp/runtime/scenario_engine.gd`:

```gdscript
@tool
extends RefCounted

# Executes scenario steps against a live scene root. FRAME-AGNOSTIC: the runner
# owns the frame loop and pumps frames for any step that returns a "frames" count
# or a "follow_up". This keeps the engine drivable from a plain headless test.
#
# A non-assert step that fails sets _fatal and returns {"ok": false, "fatal": true};
# the runner stops the run. Assertions never set _fatal — a failed assertion just
# records passed:false and the run continues.

const NodeOps = preload("res://addons/godot_mcp/utils/node_ops.gd")

# Counts a signal's emissions regardless of how many args it carries.
class SignalCounter extends RefCounted:
	var count := 0
	func inc() -> void:
		count += 1

var root: Node = null
var _index := 0
var _steps: Array = []
var _assertions: Array = []
var _signal_counters: Dictionary = {}   # "path::signal" -> SignalCounter
var _fatal := ""

func set_root(node: Node) -> void:
	root = node

func execute(step: Dictionary) -> Dictionary:
	var type := str(step.get("type", ""))
	match type:
		"wait_frames":
			var n := max(0, int(step.get("count", 0)))
			var out := _step_ok("wait_frames", "frames=%d" % n)
			out["frames"] = n
			return out
		"wait_seconds":
			var fps := int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60))
			var frames := int(ceil(float(step.get("seconds", 0.0)) * fps))
			var out := _step_ok("wait_seconds", "seconds=%s -> frames=%d" % [str(step.get("seconds", 0.0)), frames])
			out["frames"] = frames
			return out
		"input_action":
			return _input_action(step)
		"set_property":
			return _set_property(step)
		"create_node":
			return _create_node(step)
		"delete_node":
			return _delete_node(step)
		"call_method":
			return _call_method(step)
		"watch_signal":
			return _watch_signal(step)
		"assert":
			return _assert(step)
		_:
			return _step_fail("unknown", "Unknown step type: " + type)

# --- step recorders ---

func _take_index() -> int:
	var i := _index
	_index += 1
	return i

func _step_ok(type: String, detail: String) -> Dictionary:
	var rec := {"index": _take_index(), "type": type, "ok": true, "detail": detail}
	_steps.append(rec)
	return rec.duplicate()

func _step_fail(type: String, detail: String) -> Dictionary:
	var rec := {"index": _take_index(), "type": type, "ok": false, "detail": detail}
	_steps.append(rec)
	_fatal = detail
	var out := rec.duplicate()
	out["fatal"] = true
	return out

# --- step handlers ---

func _input_action(step: Dictionary) -> Dictionary:
	var action := str(step.get("action", ""))
	var mode := str(step.get("mode", "press"))
	if not InputMap.has_action(action):
		return _step_fail("input_action", "No such input action: " + action)
	var strength := float(step.get("strength", 1.0))
	match mode:
		"press":
			Input.action_press(action, strength)
			return _step_ok("input_action", "press %s (%.2f)" % [action, strength])
		"release":
			Input.action_release(action)
			return _step_ok("input_action", "release " + action)
		"tap":
			Input.action_press(action, strength)
			var out := _step_ok("input_action", "tap " + action)
			out["follow_up"] = {"type": "input_action", "action": action, "mode": "release"}
			out["follow_up_after_frames"] = 1
			return out
		_:
			return _step_fail("input_action", "Unknown input mode: " + mode)

func _set_property(step: Dictionary) -> Dictionary:
	var node := NodeOps.resolve(root, str(step.get("path", "")))
	if node == null:
		return _step_fail("set_property", "Node not found: " + str(step.get("path", "")))
	var props = step.get("properties", {})
	if typeof(props) != TYPE_DICTIONARY:
		return _step_fail("set_property", "'properties' must be an object")
	var res := NodeOps.apply_props(node, props)
	return _step_ok("set_property", "set=%s errors=%s" % [str(res["set"]), str(res["errors"])])

func _create_node(step: Dictionary) -> Dictionary:
	var parent := NodeOps.resolve(root, str(step.get("parent_path", ".")))
	if parent == null:
		return _step_fail("create_node", "Parent not found: " + str(step.get("parent_path", ".")))
	var type := str(step.get("type", ""))
	var node := NodeOps.make_node(type, str(step.get("name", type)))
	if node == null:
		return _step_fail("create_node", "Invalid node type: " + type)
	parent.add_child(node)
	node.owner = root
	var props = step.get("properties", {})
	if typeof(props) == TYPE_DICTIONARY and not props.is_empty():
		NodeOps.apply_props(node, props)
	return _step_ok("create_node", "created " + str(root.get_path_to(node)))

func _delete_node(step: Dictionary) -> Dictionary:
	var p := str(step.get("path", ""))
	if p == "" or p == ".":
		return _step_fail("delete_node", "Cannot delete the scene root")
	var node := NodeOps.resolve(root, p)
	if node == null:
		return _step_fail("delete_node", "Node not found: " + p)
	node.get_parent().remove_child(node)
	node.queue_free()
	return _step_ok("delete_node", "deleted " + p)

func _call_method(step: Dictionary) -> Dictionary:
	var node := NodeOps.resolve(root, str(step.get("path", "")))
	if node == null:
		return _step_fail("call_method", "Node not found: " + str(step.get("path", "")))
	var method := str(step.get("method", ""))
	if not node.has_method(method):
		return _step_fail("call_method", "No such method: " + method)
	var raw = step.get("args", [])
	var call_args := []
	if typeof(raw) == TYPE_ARRAY:
		for a in raw:
			call_args.append(str_to_var(str(a)))
	var ret = node.callv(method, call_args)
	return _step_ok("call_method", "%s -> %s" % [method, var_to_str(ret)])

func _watch_signal(step: Dictionary) -> Dictionary:
	var node := NodeOps.resolve(root, str(step.get("path", "")))
	if node == null:
		return _step_fail("watch_signal", "Node not found: " + str(step.get("path", "")))
	var sig := str(step.get("signal", ""))
	if not node.has_signal(sig):
		return _step_fail("watch_signal", "No such signal: " + sig)
	var argc := 0
	for s in node.get_signal_list():
		if str(s["name"]) == sig:
			argc = (s["args"] as Array).size()
			break
	var key := str(step.get("path", "")) + "::" + sig
	var counter := SignalCounter.new()
	_signal_counters[key] = counter
	var cb := Callable(counter, "inc")
	if argc > 0:
		cb = cb.unbind(argc)
	node.connect(sig, cb)
	return _step_ok("watch_signal", "watching " + key)

# Assertions arrive in Task 3; stub keeps the match exhaustive until then.
func _assert(step: Dictionary) -> Dictionary:
	return _step_fail("assert", "assertions not yet implemented")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scenario_engine.gd`
Expected: PASS — `=== 8 passed, 0 failed (test_scenario_engine.gd) ===`

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/runtime/scenario_engine.gd addons/godot_mcp/tests/test_scenario_engine.gd
git commit -m "feat: scenario engine core + non-assert steps"
```

---

## Task 3: Scenario engine — input/signal assertions + results

**Files:**
- Modify: `addons/godot_mcp/runtime/scenario_engine.gd` (replace the `_assert` stub, add `_compare`/`_numeric`/`results`)
- Modify: `addons/godot_mcp/tests/test_scenario_engine.gd` (append assertion tests)

- [ ] **Step 1: Write the failing tests**

Append to `addons/godot_mcp/tests/test_scenario_engine.gd`:

```gdscript
func test_assert_property_ops() -> void:
	var root := _make_root()
	root.get_node("Sub").position = Vector2(100, 0)
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	var gt := eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "gt", "value": "50"})
	assert_true(gt["passed"])
	var eq := eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "eq", "value": "100"})
	assert_true(eq["passed"])
	var lt := eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "lt", "value": "50"})
	assert_false(lt["passed"])
	root.free()

func test_assert_node_exists_and_absent() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_true(eng.execute({"type": "assert", "kind": "node_exists", "path": "Sub"})["passed"])
	assert_true(eng.execute({"type": "assert", "kind": "node_absent", "path": "Ghost"})["passed"])
	assert_false(eng.execute({"type": "assert", "kind": "node_exists", "path": "Ghost"})["passed"])
	root.free()

func test_assert_in_group() -> void:
	var root := _make_root()
	root.get_node("Sub").add_to_group("enemies")
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_true(eng.execute({"type": "assert", "kind": "in_group", "path": "Sub", "group": "enemies"})["passed"])
	assert_false(eng.execute({"type": "assert", "kind": "in_group", "path": "Sub", "group": "allies"})["passed"])
	root.free()

func test_watch_and_assert_signal_count() -> void:
	var root := _make_root()
	root.add_user_signal("died")
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_true(eng.execute({"type": "watch_signal", "path": ".", "signal": "died"})["ok"])
	root.emit_signal("died")
	root.emit_signal("died")
	var a := eng.execute({"type": "assert", "kind": "signal_count", "path": ".", "signal": "died", "op": "eq", "value": "2"})
	assert_true(a["passed"])
	assert_eq(a["actual"], 2)
	root.free()

func test_signal_count_without_watch_fails() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	assert_false(eng.execute({"type": "assert", "kind": "signal_count", "path": ".", "signal": "x", "op": "eq", "value": "0"})["passed"])
	root.free()

func test_results_verdict() -> void:
	var root := _make_root()
	root.get_node("Sub").position = Vector2(100, 0)
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "gt", "value": "50"})
	var r := eng.results()
	assert_true(r["ok"])
	assert_true(r["passed"])
	assert_eq(r["assertions"].size(), 1)
	# A failing assertion flips passed but keeps ok true.
	eng.execute({"type": "assert", "kind": "property", "path": "Sub", "property": "position:x", "op": "lt", "value": "0"})
	assert_true(eng.results()["ok"])
	assert_false(eng.results()["passed"])
	root.free()

func test_results_ok_false_on_fatal() -> void:
	var root := _make_root()
	var eng := ScenarioEngine.new()
	eng.set_root(root)
	eng.execute({"type": "set_property", "path": "Ghost", "properties": {}})  # fatal
	var r := eng.results()
	assert_false(r["ok"])
	assert_false(r["passed"])
	root.free()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scenario_engine.gd`
Expected: FAIL — the new assert tests fail (`_assert` still returns the stub failure; `results` undefined).

- [ ] **Step 3: Replace the `_assert` stub and add helpers**

In `addons/godot_mcp/runtime/scenario_engine.gd`, replace the entire stub `_assert` function with the following, and append `_compare`, `_numeric`, and `results` at the end of the file:

```gdscript
func _assert(step: Dictionary) -> Dictionary:
	var idx := _take_index()
	var kind := str(step.get("kind", ""))
	var path := str(step.get("path", ""))
	var rec := {"index": idx, "kind": kind, "path": path, "passed": false, "expected": "", "actual": null}
	match kind:
		"property":
			var node := NodeOps.resolve(root, path)
			if node == null:
				rec["expected"] = "node exists"
				rec["actual"] = "missing"
			else:
				var prop := str(step.get("property", ""))
				var actual = node.get_indexed(NodePath(prop))
				var op := str(step.get("op", "eq"))
				rec["actual"] = var_to_str(actual)
				rec["expected"] = "%s %s" % [op, str(step.get("value", ""))]
				rec["passed"] = _compare(actual, op, step.get("value", ""))
		"node_exists":
			rec["passed"] = NodeOps.resolve(root, path) != null
			rec["expected"] = "node exists"
			rec["actual"] = str(rec["passed"])
		"node_absent":
			rec["passed"] = NodeOps.resolve(root, path) == null
			rec["expected"] = "node absent"
			rec["actual"] = str(not rec["passed"])
		"in_group":
			var node := NodeOps.resolve(root, path)
			var grp := str(step.get("group", ""))
			rec["passed"] = node != null and node.is_in_group(grp)
			rec["expected"] = "in group " + grp
			rec["actual"] = str(rec["passed"])
		"signal_count":
			var key := path + "::" + str(step.get("signal", ""))
			var op := str(step.get("op", "eq"))
			if _signal_counters.has(key):
				var actual: int = _signal_counters[key].count
				rec["actual"] = actual
				rec["expected"] = "%s %s" % [op, str(step.get("value", ""))]
				rec["passed"] = _compare(actual, op, step.get("value", ""))
			else:
				rec["expected"] = "watched"
				rec["actual"] = "not watched"
		_:
			rec["expected"] = "known assert kind"
			rec["actual"] = kind
	_assertions.append(rec)
	return rec.duplicate()

func _numeric(v) -> bool:
	return typeof(v) in [TYPE_INT, TYPE_FLOAT]

func _compare(actual, op: String, expected_raw) -> bool:
	var expected = str_to_var(str(expected_raw))
	match op:
		"eq":
			return NodeOps.value_applied(actual, expected)
		"ne":
			return not NodeOps.value_applied(actual, expected)
		"lt", "le", "gt", "ge":
			if not _numeric(actual) or not _numeric(expected):
				return false
			var a := float(actual)
			var b := float(expected)
			if op == "lt": return a < b
			if op == "le": return a <= b
			if op == "gt": return a > b
			return a >= b
	return false

# Accumulated results. ok = no fatal step; passed = ok AND every assertion passed.
# The runner attaches scene/frames_run/errors/log.
func results() -> Dictionary:
	var any_fail := false
	for a in _assertions:
		if not a.get("passed", false):
			any_fail = true
	return {
		"ok": _fatal == "",
		"passed": _fatal == "" and not any_fail,
		"fatal": _fatal,
		"steps": _steps,
		"assertions": _assertions,
	}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_scenario_engine.gd`
Expected: PASS — all engine tests green (15 passed, 0 failed).

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/runtime/scenario_engine.gd addons/godot_mcp/tests/test_scenario_engine.gd
git commit -m "feat: scenario engine assertions and run verdict"
```

---

## Task 4: Scenario runner (SceneTree main loop)

**Files:**
- Create: `addons/godot_mcp/runtime/scenario_runner.gd`

The live frame loop is verified manually (Task 5 E2E), per the design — not unit-tested.

- [ ] **Step 1: Create `scenario_runner.gd`**

Create `addons/godot_mcp/runtime/scenario_runner.gd`:

```gdscript
@tool
extends SceneTree

# Headless scenario runner. Launch:
#   godot4 --headless --path . --script addons/godot_mcp/runtime/scenario_runner.gd \
#          -- --scenario <path> --out <path>
# Loads the scenario's scene, pumps physics frames while delegating steps to
# scenario_engine.gd, writes a results JSON, and exits 0 iff all assertions passed.

const ScenarioEngine = preload("res://addons/godot_mcp/runtime/scenario_engine.gd")
const OutputCapture = preload("res://addons/godot_mcp/tools/output_capture.gd")

func _initialize() -> void:
	var args := _parse_args()
	if not args.has("scenario") or not args.has("out"):
		push_error("scenario_runner: --scenario <path> --out <path> required")
		quit(2)
		return
	# Run the loop as a coroutine; it resumes on physics_frame and quits when done.
	_main(args["scenario"], args["out"])

func _parse_args() -> Dictionary:
	var out := {}
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		var a := str(argv[i])
		if a == "--scenario" and i + 1 < argv.size():
			out["scenario"] = str(argv[i + 1])
			i += 2
		elif a == "--out" and i + 1 < argv.size():
			out["out"] = str(argv[i + 1])
			i += 2
		else:
			i += 1
	return out

func _main(scenario_path: String, out_path: String) -> void:
	var logger := OutputCapture.new()
	OS.add_logger(logger)

	var parsed := _load_scenario(scenario_path)
	if not parsed["ok"]:
		_write_results(out_path, _fail_results("", parsed["error"], logger))
		quit(2)
		return
	var scenario: Dictionary = parsed["value"]
	var scene_path := str(scenario.get("scene", ""))

	var packed = load(scene_path)
	if packed == null or not (packed is PackedScene):
		_write_results(out_path, _fail_results(scene_path, "Could not load scene: " + scene_path, logger))
		quit(2)
		return

	var inst: Node = (packed as PackedScene).instantiate()
	root.add_child(inst)
	current_scene = inst
	await physics_frame  # let _enter_tree/_ready settle

	var eng := ScenarioEngine.new()
	eng.set_root(inst)
	var frames_run := 0
	for step in scenario.get("steps", []):
		var res: Dictionary = eng.execute(step)
		if res.has("frames"):
			for _i in int(res["frames"]):
				await physics_frame
				frames_run += 1
		if res.has("follow_up"):
			for _j in int(res.get("follow_up_after_frames", 1)):
				await physics_frame
				frames_run += 1
			eng.execute(res["follow_up"])
		if res.get("fatal", false):
			break

	var out := eng.results()
	out["scene"] = scene_path
	out["frames_run"] = frames_run
	out["errors"] = _errors(logger)
	out["log"] = _log_tail(logger)
	_write_results(out_path, out)
	quit(0 if out.get("passed", false) else 1)

func _load_scenario(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "Scenario file not found: " + path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Could not open scenario: " + path}
	var text := f.get_as_text()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok": false, "error": "Invalid scenario JSON: " + json.get_error_message()}
	if typeof(json.data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "Scenario root must be a JSON object"}
	return {"ok": true, "value": json.data}

func _fail_results(scene: String, error: String, logger) -> Dictionary:
	return {
		"ok": false, "passed": false, "scene": scene, "frames_run": 0,
		"steps": [], "assertions": [], "errors": _errors(logger),
		"log": _log_tail(logger), "error": error,
	}

func _errors(logger) -> Array:
	return logger.entries(0, true)

func _log_tail(logger) -> Array:
	return logger.entries(200, false)

func _write_results(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("scenario_runner: could not write results to " + path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.flush()
```

- [ ] **Step 2: Smoke-run with a missing scenario to confirm clean failure + exit code**

Run:
```bash
godot4 --headless --path . --script addons/godot_mcp/runtime/scenario_runner.gd -- --scenario /tmp/nope.json --out /tmp/r.json; echo "exit=$?"; cat /tmp/r.json
```
Expected: `exit=2`; `/tmp/r.json` contains `"ok": false` and an `"error"` mentioning the missing file.

- [ ] **Step 3: Commit**

```bash
git add addons/godot_mcp/runtime/scenario_runner.gd
git commit -m "feat: headless scenario runner main loop"
```

---

## Task 5: Launch wrapper, E2E fixture, and docs

**Files:**
- Create: `addons/godot_mcp/runtime/run_scenario.sh`
- Create: `examples/scripts/runner_demo.gd`, `examples/scenes/runner_demo.tscn`, `examples/scenarios/move_right.json`
- Modify: `docs/E2E_TESTING.md`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: Create the launch wrapper**

Create `addons/godot_mcp/runtime/run_scenario.sh`:

```bash
#!/usr/bin/env bash
# Run one scenario headless and write results JSON.
# Usage: run_scenario.sh <scenario.json> <out.json>
# Honors $GODOT (default: godot4). Exit code mirrors the run verdict
# (0 = all assertions passed).
set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GODOT="${GODOT:-godot4}"
SCENARIO="${1:?usage: run_scenario.sh <scenario.json> <out.json>}"
OUT="${2:?usage: run_scenario.sh <scenario.json> <out.json>}"
"$GODOT" --headless --path "$PROJECT_ROOT" \
	--script addons/godot_mcp/runtime/scenario_runner.gd \
	-- --scenario "$SCENARIO" --out "$OUT"
```

Then: `chmod +x addons/godot_mcp/runtime/run_scenario.sh`

- [ ] **Step 2: Create the E2E fixture script**

Create `examples/scripts/runner_demo.gd`:

```gdscript
extends Node2D
# Manual-E2E fixture for the headless scenario runner. Moves right while the
# built-in "ui_right" action is held and fires reached_goal once it passes x=100.

signal reached_goal

var speed := 400.0
var _fired := false

func _physics_process(delta: float) -> void:
	if Input.is_action_pressed("ui_right"):
		position.x += speed * delta
		if position.x >= 100.0 and not _fired:
			_fired = true
			emit_signal("reached_goal")
```

- [ ] **Step 3: Create the E2E fixture scene**

Create `examples/scenes/runner_demo.tscn`:

```
[gd_scene load_steps=2 format=3 uid="uid://b8mcprunnerdemo0"]

[ext_resource type="Script" path="res://examples/scripts/runner_demo.gd" id="1"]

[node name="Demo" type="Node2D"]
script = ExtResource("1")
```

- [ ] **Step 4: Create the sample scenario**

Create `examples/scenarios/move_right.json`:

```json
{
  "scene": "res://examples/scenes/runner_demo.tscn",
  "steps": [
    { "type": "watch_signal", "path": ".", "signal": "reached_goal" },
    { "type": "input_action", "action": "ui_right", "mode": "press" },
    { "type": "wait_seconds", "seconds": 1.0 },
    { "type": "input_action", "action": "ui_right", "mode": "release" },
    { "type": "assert", "kind": "property", "path": ".", "property": "position:x", "op": "gt", "value": "100" },
    { "type": "assert", "kind": "signal_count", "path": ".", "signal": "reached_goal", "op": "eq", "value": "1" }
  ]
}
```

- [ ] **Step 5: Run the full E2E and verify the verdict**

Run:
```bash
addons/godot_mcp/runtime/run_scenario.sh examples/scenarios/move_right.json /tmp/move_right.json; echo "exit=$?"; cat /tmp/move_right.json
```
Expected: `exit=0`; JSON shows `"ok": true`, `"passed": true`, both assertions `"passed": true`, `position:x` greater than 100, and `reached_goal` count 1.

- [ ] **Step 6: Document in `docs/E2E_TESTING.md`**

Append a new section to `docs/E2E_TESTING.md`:

```markdown
## Headless scenario runner

The runtime scenario runner drives a real scene headlessly (no editor). Author a
scenario JSON (target scene + ordered steps), run it, read the results JSON:

```bash
addons/godot_mcp/runtime/run_scenario.sh examples/scenarios/move_right.json /tmp/out.json
echo "exit=$?"   # 0 = every assertion passed
cat /tmp/out.json
```

`examples/scenarios/move_right.json` against `examples/scenes/runner_demo.tscn`
should report `passed: true`: it holds `ui_right` for ~1s, asserts the node moved
past x=100, and that `reached_goal` fired once.

Step types: `wait_frames`, `wait_seconds`, `input_action` (modes `press`/`release`/`tap`),
`set_property`, `create_node`, `delete_node`, `call_method`, `watch_signal`, and
`assert` (kinds `property`, `node_exists`, `node_absent`, `in_group`, `signal_count`;
ops `eq`/`ne`/`lt`/`le`/`gt`/`ge`). Input is action-based (project input map) and
poll-observable (`Input.is_action_pressed`); it does not fire `_input`/`_unhandled_input`.
```

- [ ] **Step 7: Document in `README.md`**

In `README.md`, change the `- **Run/feedback** *(pending)*` bullet (around line 118) to mark the runtime runner as implemented:

```markdown
- **Runtime (headless scenario runner)** *(implemented)*: `addons/godot_mcp/runtime/run_scenario.sh`
  launches a separate `--headless` Godot process that runs a real scene, drives it with
  input-map actions, manipulates/inspects live nodes, and writes a pass/fail results JSON
  (no editor, no HTTP server in the game). Step types: `wait_frames`/`wait_seconds`,
  `input_action`, `set_property`, `create_node`/`delete_node`, `call_method`, `watch_signal`,
  and `assert`. Action input is poll-observable only; raw key/mouse `InputEvent` synthesis,
  `_input` delivery, and screenshots remain deferred.
```

- [ ] **Step 8: Document in `CLAUDE.md`**

In `CLAUDE.md`, under "## Scope", append a paragraph after the v1 tool list:

```markdown
Beyond the in-editor MCP tools, a **headless scenario runner** (`addons/godot_mcp/runtime/`)
lets Claude launch a separate `--headless` Godot process that runs a real scene, drives it
with input-map actions, and manipulates/inspects live runtime nodes, emitting a pass/fail
results JSON. It is launched via Bash (`runtime/run_scenario.sh`), not over MCP, and shares
node-manipulation logic with the editor tools through `utils/node_ops.gd`. Action input is
poll-observable only; raw `InputEvent` synthesis and screenshots are deferred (v2).
```

Also update the "Commands" section of `CLAUDE.md` to add, after the single-suite example:

```markdown
# Run a headless scenario (runtime testing, separate from the unit suite):
addons/godot_mcp/runtime/run_scenario.sh examples/scenarios/move_right.json /tmp/out.json
```

- [ ] **Step 9: Run the full unit suite to confirm nothing regressed**

Run: `./addons/godot_mcp/run_tests.sh`
Expected: every suite passes, `>>> suites failed: 0` (now including `test_node_ops.gd` and `test_scenario_engine.gd`).

- [ ] **Step 10: Commit**

```bash
git add addons/godot_mcp/runtime/run_scenario.sh examples/scripts/runner_demo.gd examples/scenes/runner_demo.tscn examples/scenarios/move_right.json docs/E2E_TESTING.md README.md CLAUDE.md
git commit -m "feat: scenario runner launch wrapper, E2E fixture, and docs"
```

---

## Self-Review

**Spec coverage:**
- Deterministic runner, Bash-launched, one process per scenario → Task 4 + Task 5 wrapper. ✓
- JSON results file, no HTTP/MCP in game → Task 4 `_write_results`. ✓
- Action-based input only → Task 2 `_input_action` (press/release/tap). ✓
- Built-in assertions with verdict → Task 3 (`property`/`node_exists`/`node_absent`/`in_group`/`signal_count`; ops eq/ne/lt/le/gt/ge). ✓
- Reuse via extraction into `utils/node_ops.gd` → Task 1. ✓
- Step vocabulary (wait/input/set_property/call_method/create/delete/watch_signal/assert) → Tasks 2–3. ✓
- Results shape (ok/passed/frames_run/steps/assertions/errors/log) → Task 3 `results` + Task 4 attaches scene/frames_run/errors/log. ✓
- v1 limitation (poll-only input) → documented in Tasks 5/7/8 and design. ✓
- Tests: test_node_ops, test_scenario_engine; scene_tools suite guards refactor; runner via E2E → Tasks 1–5. ✓

**Placeholder scan:** No TBD/TODO. The Task 2 `_assert` is a deliberate, functional stub (returns a real failure result, keeps `match` exhaustive) explicitly replaced in Task 3 Step 3 — not a placeholder.

**Type consistency:** `NodeOps.{resolve,make_node,decode_props,value_applied,apply_props,encode_props,serialize_tree}` are defined in Task 1 and called identically in Tasks 1–3. Engine surface `set_root`/`execute`/`results` and step result keys (`ok`, `fatal`, `frames`, `follow_up`, `follow_up_after_frames`, `passed`, `actual`, `expected`) are used consistently across engine (Tasks 2–3), runner (Task 4), and tests. `OutputCapture.entries(limit, errors_only)` matches the real signature in `tools/output_capture.gd`.
