extends Node
# Minimal game-side adapter fixture, independent of any settlement implementation.
var tick := 0

func _enter_tree() -> void:
	add_to_group("godot_mcp_simulation_adapter")

func mcp_simulation_capabilities() -> Dictionary:
	return {"supported_sections": ["jobs", "reservations", "inventories", "paths", "power", "needs"], "can_advance_ticks": false}

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
