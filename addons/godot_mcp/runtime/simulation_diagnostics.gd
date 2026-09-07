extends RefCounted
const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
var _advance_task
var _controlled_adapter: Node
const GROUP := "godot_mcp_simulation_adapter"
const SECTIONS := ["jobs", "reservations", "inventories", "paths", "power", "needs"]
var bridge: Node
func _init(owner: Node) -> void:
	bridge = owner

static func select_adapter(nodes: Array) -> Dictionary:
	if nodes.size() != 1:
		return {"ok": false, "error": "Expected exactly one node in group " + GROUP + "; found " + str(nodes.size())}
	var adapter: Node = nodes[0]
	if not adapter.has_method("mcp_simulation_capabilities") or not adapter.has_method("mcp_simulation_snapshot"):
		return {"ok": false, "error": "Simulation adapter is missing required methods"}
	return {"ok": true, "value": adapter}

func snapshot(args: Dictionary) -> Dictionary:
	var selected := select_adapter(bridge.get_tree().get_nodes_in_group(GROUP))
	if not selected.ok:
		return selected
	return read_adapter(selected.value, args)

static func read_adapter(adapter: Node, args: Dictionary) -> Dictionary:
	var capabilities: Variant = adapter.call("mcp_simulation_capabilities")
	if not capabilities is Dictionary or not capabilities.get("supported_sections") is Array or not capabilities.get("can_advance_ticks") is bool or not json_safe(capabilities):
		return {"ok": false, "error": "Invalid simulation adapter capabilities"}
	for section in capabilities.supported_sections:
		if section not in SECTIONS:
			return {"ok": false, "error": "Adapter advertises an unknown section"}
	var requested: Variant = args.get("sections", capabilities.supported_sections)
	if not requested is Array or requested.size() > 6:
		return {"ok": false, "error": "sections must be an array of at most six names"}
	var unsupported := []
	var supported := []
	for section in requested:
		if not section is String:
			return {"ok": false, "error": "Section names must be strings"}
		if section in capabilities.supported_sections:
			if section not in supported:
				supported.append(section)
		else:
			unsupported.append(section)
	var filters := {"sections": supported}
	if args.has("entity_ids"):
		if not args.entity_ids is Array or args.entity_ids.size() > 1000:
			return {"ok": false, "error": "entity_ids must be an array of at most 1000 strings"}
		for id in args.entity_ids:
			if not id is String:
				return {"ok": false, "error": "entity_ids must contain strings"}
		filters["entity_ids"] = args.entity_ids.duplicate()
	var snapshot: Variant = adapter.call("mcp_simulation_snapshot", filters)
	if not snapshot is Dictionary or not json_safe(snapshot) or snapshot.get("schema_version") != 1 or not snapshot.get("data") is Dictionary:
		return {"ok": false, "error": "Invalid JSON-safe simulation snapshot"}
	var tick: Variant = snapshot.get("tick")
	if not (typeof(tick) in [TYPE_INT, TYPE_FLOAT]) or tick < 0 or tick > 9007199254740991 or tick != floor(tick):
		return {"ok": false, "error": "Simulation snapshot requires an authoritative nonnegative integer tick"}
	for section in supported:
		if not snapshot.data.has(section):
			return {"ok": false, "error": "Adapter omitted requested supported section: " + section}
	var data := {}
	for section in supported:
		data[section] = snapshot.data[section]
	var value := {"schema_version": 1, "tick": int(tick), "capabilities": capabilities, "data": data, "unsupported_sections": unsupported}
	if JSON.stringify(value).to_utf8_buffer().size() > 12 * 1024 * 1024:
		return {"ok": false, "error": "Simulation snapshot too large; filter sections or entity_ids"}
	return {"ok": true, "value": value}

static func json_safe(value: Variant) -> bool:
	return _json_safe(value, 0, {"remaining": 100000})

static func _json_safe(value: Variant, depth: int, budget: Dictionary) -> bool:
	budget.remaining -= 1
	if depth > 16 or budget.remaining < 0:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(value)
		TYPE_ARRAY:
			for element in value:
				if not _json_safe(element, depth + 1, budget):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if not key is String or not _json_safe(value[key], depth + 1, budget):
					return false
			return true
	return false

func advance(args: Dictionary):
	var task := Deferred.new(30)
	if _advance_task != null and not _advance_task.done:
		task.resolve({"ok": false, "error": "Another simulation advancement is running"})
		return task
	var count: Variant = args.get("ticks")
	if not (typeof(count) in [TYPE_INT, TYPE_FLOAT]) or not is_finite(count) or count != floor(count) or count < 1 or count > 10000:
		task.resolve({"ok": false, "error": "ticks must be an integer from 1 to 10000"})
		return task
	var selected := select_adapter(bridge.get_tree().get_nodes_in_group(GROUP))
	if not selected.ok:
		task.resolve(selected)
		return task
	var adapter: Node = selected.value
	var initial := read_adapter(adapter, {"sections": []})
	if not initial.ok:
		task.resolve(initial)
		return task
	if not initial.value.capabilities.can_advance_ticks or not adapter.has_method("mcp_simulation_set_controlled") or not adapter.has_method("mcp_simulation_advance_tick"):
		task.resolve({"ok": false, "error": "Simulation adapter does not support exact tick advancement"})
		return task
	var controlled: Variant = adapter.call("mcp_simulation_set_controlled", true)
	if not controlled is Dictionary or not controlled.get("ok") is bool or not controlled.ok:
		task.resolve({"ok": false, "error": "Adapter could not enter controlled simulation mode"})
		return task
	_controlled_adapter = adapter
	initial = read_adapter(adapter, {"sections": []})
	if not initial.ok:
		task.resolve(initial)
		return task
	_advance_task = task
	var progress := {"tick_before": initial.value.tick, "tick_after": initial.value.tick, "advanced_ticks": 0, "paused": true}
	task.on_cancel = func(): _advance_failure(task, progress, "Advancement cancelled or timed out; completed ticks are not rolled back")
	_advance_loop(task, adapter, int(count), progress)
	return task

func _advance_loop(task, adapter: Node, count: int, progress: Dictionary) -> void:
	var slice_start := Time.get_ticks_usec()
	for _i in count:
		if task.done:
			return
		if not is_instance_valid(adapter) or not adapter.is_inside_tree():
			_advance_failure(task, progress, "Simulation adapter left the running scene")
			return
		var step: Variant = adapter.call("mcp_simulation_advance_tick")
		if not valid_tick_result(step, int(progress.tick_after) + 1):
			# Snapshot actual progress after failure; the adapter may have mutated
			# before returning an error. Never pretend to roll that tick back.
			var actual := read_adapter(adapter, {"sections": []})
			if actual.ok:
				progress.tick_after = actual.value.tick
				progress.advanced_ticks = progress.tick_after - progress.tick_before
			_advance_failure(task, progress, "Adapter tick failed or did not increment by exactly one")
			return
		progress.tick_after = step.tick
		progress.advanced_ticks += 1
		if (_i + 1) % 64 == 0 or Time.get_ticks_usec() - slice_start >= 3000:
			await bridge.get_tree().process_frame
			slice_start = Time.get_ticks_usec()
	_advance_task = null
	task.resolve({"ok": true, "value": progress})

func _advance_failure(task, progress: Dictionary, message: String) -> void:
	if _advance_task == task:
		_advance_task = null
	var detail := progress.duplicate(true)
	detail["message"] = message
	task.resolve({"ok": false, "error": JSON.stringify(detail)})

func cleanup() -> void:
	if _advance_task != null:
		_advance_task.cancel("Runtime stopped")
	if is_instance_valid(_controlled_adapter):
		_controlled_adapter.call("mcp_simulation_set_controlled", false)
	_controlled_adapter = null

static func valid_tick_result(step: Variant, expected: int) -> bool:
	if not step is Dictionary or not step.get("ok") is bool or not step.ok:
		return false
	var tick: Variant = step.get("tick")
	return typeof(tick) in [TYPE_INT, TYPE_FLOAT] and is_finite(tick) and tick == expected
