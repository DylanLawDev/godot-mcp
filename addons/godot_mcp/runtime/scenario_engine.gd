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
const FrameCapture = preload("res://addons/godot_mcp/runtime/frame_capture.gd")
const TextureDump = preload("res://addons/godot_mcp/utils/texture_dump.gd")

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
var _captures: Dictionary = {}          # capture dir -> FrameCapture
var _fatal := ""

func set_root(node: Node) -> void:
	root = node

# The SceneTree whose pause flag set_paused flips. The runner injects itself;
# without an injection we fall back to the registered main loop (null while a
# SceneTree script is still in _init — which is where the unit suite runs).
var _tree: SceneTree = null

func set_tree(tree: SceneTree) -> void:
	_tree = tree

func _scene_tree() -> SceneTree:
	if _tree != null:
		return _tree
	var ml := Engine.get_main_loop()
	return ml as SceneTree if ml is SceneTree else null

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
		"capture_frames":
			return _capture_frames(step)
		"set_paused":
			return _set_paused(step)
		"step_frames":
			return _step_frames(step)
		"capture_texture":
			return _capture_texture(step)
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
	# A requested property that doesn't apply means the runtime state wasn't
	# established — fail the step (fatal, per this engine's non-assert contract)
	# rather than silently recording ok:true and letting the run pass.
	if not (res["errors"] as Array).is_empty():
		return _step_fail("set_property", "set=%s errors=%s" % [str(res["set"]), str(res["errors"])])
	return _step_ok("set_property", "set=%s" % str(res["set"]))

func _create_node(step: Dictionary) -> Dictionary:
	var parent := NodeOps.resolve(root, str(step.get("parent_path", ".")))
	if parent == null:
		return _step_fail("create_node", "Parent not found: " + str(step.get("parent_path", ".")))
	var node_class := str(step.get("node_type", ""))
	var node := NodeOps.make_node(node_class, str(step.get("name", node_class)))
	if node == null:
		return _step_fail("create_node", "Invalid node type: " + node_class)
	parent.add_child(node)
	node.owner = root
	var props = step.get("properties", {})
	if typeof(props) == TYPE_DICTIONARY and not props.is_empty():
		var res := NodeOps.apply_props(node, props)
		# Same contract as set_property: a property that doesn't apply is a setup
		# failure, even though the node itself was created and added.
		if not (res["errors"] as Array).is_empty():
			return _step_fail("create_node", "created %s but errors=%s" % [str(root.get_path_to(node)), str(res["errors"])])
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

# Registers a burst capture: the runner pumps `count` RENDER frames (awaiting
# process_frame, not physics_frame, so each grab follows a fresh draw) and calls
# capture_for(dir).capture(viewport) after each. The engine only validates and
# prepares the destination — it never touches the viewport, staying
# frame-agnostic and unit-testable.
func _capture_frames(step: Dictionary) -> Dictionary:
	var count := int(step.get("count", 1))
	if count < 1:
		return _step_fail("capture_frames", "'count' must be >= 1")
	var dir := str(step.get("dir", ""))
	if dir.strip_edges() == "":
		return _step_fail("capture_frames", "'dir' is required")
	var prep := _prepare_capture(dir, step)
	if not prep["ok"]:
		return _step_fail("capture_frames", prep["error"])
	var out := _step_ok("capture_frames", "count=%d dir=%s" % [count, dir])
	out["capture_frames"] = count
	out["capture_dir"] = dir
	return out

# Get-or-create the FrameCapture for a dir (one numbering sequence per dir).
# A reused dir keeps its numbering AND its downscale — unless the new step
# explicitly specifies "downscale", which is applied to the remaining frames
# (an omitted key never silently resets an earlier choice).
func _prepare_capture(dir: String, step: Dictionary) -> Dictionary:
	var existing: FrameCapture = _captures.get(dir)
	if existing != null:
		if step.has("downscale"):
			existing.downscale = max(1, int(step.get("downscale", 1)))
		return {"ok": true, "error": ""}
	var cap := FrameCapture.new()
	var conf := cap.configure(dir, int(step.get("downscale", 1)))
	if conf["ok"]:
		_captures[dir] = cap
	return conf

# Pauses/unpauses the whole tree (SceneTree.paused): _process/_physics_process
# stop for every node not opting out via process_mode.
func _set_paused(step: Dictionary) -> Dictionary:
	var tree := _scene_tree()
	if tree == null:
		return _step_fail("set_paused", "No SceneTree to pause")
	var p := bool(step.get("paused", true))
	tree.paused = p
	return _step_ok("set_paused", "paused=" + str(p))

# Frame stepping: the runner advances the tree exactly `count` frames, one at a
# time (unpause -> await one process_frame -> re-pause; verified to run _process
# exactly once per step), capturing after each if "dir" is given. The tree is
# left PAUSED afterward regardless of its prior state — resume with set_paused.
func _step_frames(step: Dictionary) -> Dictionary:
	var count := int(step.get("count", 1))
	if count < 1:
		return _step_fail("step_frames", "'count' must be >= 1")
	var dir := str(step.get("dir", ""))
	if step.has("dir") and dir.strip_edges() == "":
		return _step_fail("step_frames", "'dir' must not be blank")
	if dir != "":
		var prep := _prepare_capture(dir, step)
		if not prep["ok"]:
			return _step_fail("step_frames", prep["error"])
	var out := _step_ok("step_frames", "count=%d%s" % [count, "" if dir == "" else " dir=" + dir])
	out["step_frames"] = count
	if dir != "":
		out["capture_dir"] = dir
	return out

# The runner's handle to a prepared capture destination.
func capture_for(dir: String) -> FrameCapture:
	return _captures.get(dir)
# Reads back a texture reachable from a live node — a SubViewport's render
# target (empty "property") or any Texture2D-holding property path — and saves
# it as a PNG at "out". Failure is fatal: an explicitly requested readback that
# produces nothing means the run's premise is broken. GPU-backed textures
# (ViewportTexture) need the windowed --render mode; CPU textures (ImageTexture)
# work headless too. Logic lives in utils/texture_dump.gd, shared with the
# editor's capture_texture MCP tool.
func _capture_texture(step: Dictionary) -> Dictionary:
	var node := NodeOps.resolve(root, str(step.get("path", "")))
	if node == null:
		return _step_fail("capture_texture", "Node not found: " + str(step.get("path", "")))
	var res := TextureDump.dump_to_png(node, str(step.get("property", "")), str(step.get("out", "")))
	if not res["ok"]:
		return _step_fail("capture_texture", res["error"])
	return _step_ok("capture_texture", "%s (%dx%d)" % [res["path"], res["width"], res["height"]])

func _watch_signal(step: Dictionary) -> Dictionary:
	var node := NodeOps.resolve(root, str(step.get("path", "")))
	if node == null:
		return _step_fail("watch_signal", "Node not found: " + str(step.get("path", "")))
	var sig := str(step.get("signal", ""))
	if not node.has_signal(sig):
		return _step_fail("watch_signal", "No such signal: " + sig)
	var key := str(step.get("path", "")) + "::" + sig
	if _signal_counters.has(key):
		(_signal_counters[key] as SignalCounter).count = 0
		return _step_ok("watch_signal", "re-watching " + key)
	var argc := 0
	for s in node.get_signal_list():
		if str(s["name"]) == sig:
			argc = (s["args"] as Array).size()
			break
	var counter := SignalCounter.new()
	_signal_counters[key] = counter
	var cb := Callable(counter, "inc")
	if argc > 0:
		cb = cb.unbind(argc)
	node.connect(sig, cb)
	return _step_ok("watch_signal", "watching " + key)

# Record an assertion verdict. `actual` is stringified via var_to_str for the
# `property` kind (the value can be any Variant — Vector2, Color — with no clean
# JSON form) and for the boolean kinds; `signal_count` keeps it a raw int.
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
	# Expected values follow the codebase convention (NodeOps.decode_props): a JSON
	# string holding a Godot variant literal — "100" -> int, "Vector2(1,0)" -> Vector2.
	# A plain string like "Player" is not a valid literal (str_to_var returns null),
	# so fall back to the raw string for that case so string properties can be
	# asserted directly; an explicit "null" literal is preserved as null.
	var raw := str(expected_raw)
	var expected = str_to_var(raw)
	if expected == null and raw != "null":
		expected = raw
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
# A scenario with zero assertions is vacuously passed:true (a capture-only run);
# add at least one assert step to get a meaningful verdict.
# The runner attaches scene/frames_run/errors/log.
func results() -> Dictionary:
	var any_fail := false
	for a in _assertions:
		if not a.get("passed", false):
			any_fail = true
	var out := {
		"ok": _fatal == "",
		"passed": _fatal == "" and not any_fail,
		"fatal": _fatal,
		"steps": _steps,
		"assertions": _assertions,
	}
	if not _captures.is_empty():
		var manifests := []
		for dir in _captures:
			manifests.append(_captures[dir].manifest())
		out["captures"] = manifests
	return out
