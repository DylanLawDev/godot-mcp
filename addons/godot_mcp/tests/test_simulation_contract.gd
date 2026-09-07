extends "res://addons/godot_mcp/tests/test_case.gd"
const Diagnostics = preload("res://addons/godot_mcp/runtime/simulation_diagnostics.gd")
class Adapter:
	extends Node
	var data: Variant = null
	var version: Variant = 1
	func mcp_simulation_capabilities():
		return {"supported_sections": ["jobs"], "can_advance_ticks": false}
	func mcp_simulation_snapshot(_filters):
		return {"schema_version": version, "tick": 0, "data": {"jobs": data}}
func test_sections_require_record_arrays_and_safe_integers() -> void:
	var adapter := Adapter.new()
	for invalid in [null, 4, {}, ["not an object"]]:
		adapter.data = invalid
		assert_false(Diagnostics.read_adapter(adapter, {}).ok)
	adapter.data = [{"id": "job-1"}]
	assert_true(Diagnostics.read_adapter(adapter, {}).ok)
	adapter.version = "1"
	assert_false(Diagnostics.read_adapter(adapter, {}).ok)
	assert_false(Diagnostics.json_safe({"count": 9007199254740992}))
	assert_false(Diagnostics.json_safe({"count": -9007199254740992}))
	assert_true(Diagnostics.json_safe({"count": "9007199254740992"}))
	adapter.free()
