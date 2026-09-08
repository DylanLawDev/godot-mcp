extends SceneTree
const Simulation = preload("res://addons/godot_mcp/runtime/simulation_diagnostics.gd")
class Adapter extends Node:
	var tick := 9007199254740990
	var controlled := false
	var stepped := false
	func _enter_tree() -> void:
		add_to_group("godot_mcp_simulation_adapter")
	func mcp_simulation_capabilities() -> Dictionary:
		return {"supported_sections": [], "can_advance_ticks": true}
	func mcp_simulation_snapshot(_filters: Dictionary) -> Dictionary:
		return {"schema_version": 1, "tick": tick, "data": {}}
	func mcp_simulation_set_controlled(enabled: bool) -> Dictionary:
		controlled = enabled
		if enabled:
			tick += 1
		return {"ok": true}
	func mcp_simulation_advance_tick() -> Dictionary:
		stepped = true
		return {"ok": false}
func _initialize() -> void:
	_main.call_deferred()
func _main() -> void:
	var adapter := Adapter.new()
	root.add_child(adapter)
	var simulation := Simulation.new(adapter)
	var task = simulation.advance({"ticks": 1})
	var detail: Variant = JSON.parse_string(task.value.get("error", ""))
	var passed: bool = not task.value.ok and detail is Dictionary and detail.paused and detail.tick_after == 9007199254740991 and detail.advanced_ticks == 0 and not adapter.stepped
	simulation.cleanup()
	adapter.queue_free()
	print("TICK BOUNDARY INTEGRATION: ", passed)
	quit(0 if passed else 1)
