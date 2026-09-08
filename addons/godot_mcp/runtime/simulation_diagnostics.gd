extends RefCounted
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
	if not snapshot is Dictionary or not json_safe(snapshot) or typeof(snapshot.get("schema_version")) not in [TYPE_INT, TYPE_FLOAT] or snapshot.get("schema_version") != 1 or not snapshot.get("data") is Dictionary:
		return {"ok": false, "error": "Invalid JSON-safe simulation snapshot"}
	var tick: Variant = snapshot.get("tick")
	if not (typeof(tick) in [TYPE_INT, TYPE_FLOAT]) or tick < 0 or tick > 9007199254740991 or tick != floor(tick):
		return {"ok": false, "error": "Simulation snapshot requires an authoritative nonnegative integer tick"}
	for section in supported:
		if not snapshot.data.has(section) or not snapshot.data[section] is Array:
			return {"ok": false, "error": "Adapter must return a record array for section: " + section}
		for record in snapshot.data[section]:
			if not record is Dictionary:
				return {"ok": false, "error": "Simulation section records must be objects"}
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
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return true
		TYPE_INT:
			return value >= -9007199254740991 and value <= 9007199254740991
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
