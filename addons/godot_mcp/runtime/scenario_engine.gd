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
	var node_class := str(step.get("node_type", ""))
	var node := NodeOps.make_node(node_class, str(step.get("name", node_class)))
	if node == null:
		return _step_fail("create_node", "Invalid node type: " + node_class)
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

# Assertions arrive in Task 3; stub keeps the match exhaustive until then.
func _assert(step: Dictionary) -> Dictionary:
	return _step_fail("assert", "assertions not yet implemented")
