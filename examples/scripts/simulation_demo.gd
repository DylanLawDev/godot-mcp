extends Node
# Minimal game-side adapter fixture, independent of any settlement implementation.
@export var fail_after_tick := -1
var tick := 0
var visual_frames := 0
var _controlled := true

func _enter_tree() -> void:
	add_to_group("godot_mcp_simulation_adapter")

func mcp_simulation_capabilities() -> Dictionary:
	return {"supported_sections": ["jobs", "reservations", "inventories", "paths", "power", "needs"], "can_advance_ticks": true}

func mcp_simulation_snapshot(filters: Dictionary) -> Dictionary:
	var sections := {
		"jobs": [{"id": "job-1", "entity_id": "settler-1", "worker_id": "settler-1", "resource_id": "wood-1", "progress": tick}],
		"reservations": [{"id": "reservation-1", "entity_id": "settler-1", "job_id": "job-1", "resource_id": "wood-1", "amount": 1}],
		"inventories": [{"entity_id": "settler-1", "items": {"wood": tick}}],
		"paths": [{"entity_id": "settler-1", "points": [[tick, 0], [tick + 1, 0]]}],
		"power": [{"entity_id": "settler-1", "consumer_id": "workbench-1", "available": true}],
		"needs": [{"entity_id": "settler-1", "hunger": minf(1.0, float(tick) / 100.0)}]
	}
	var data := {}
	for section in filters.get("sections", sections.keys()):
		data[section] = sections[section] if not filters.has("entity_ids") or "settler-1" in filters.entity_ids else []
	return {"schema_version": 1, "tick": tick, "data": data}

func _process(_delta: float) -> void:
	visual_frames += 1

func _physics_process(_delta: float) -> void:
	if not _controlled:
		tick += 1

func mcp_simulation_set_controlled(enabled: bool) -> Dictionary:
	_controlled = enabled
	return {"ok": true}

func mcp_simulation_advance_tick() -> Dictionary:
	if not _controlled:
		return {"ok": false, "error": "Simulation is not controlled"}
	if fail_after_tick >= 0 and tick >= fail_after_tick:
		return {"ok": false, "error": "Injected fixture tick failure"}
	tick += 1
	return {"ok": true, "tick": tick}
