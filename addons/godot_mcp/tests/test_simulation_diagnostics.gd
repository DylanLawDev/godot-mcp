extends "res://addons/godot_mcp/tests/test_case.gd"
const Diagnostics = preload("res://addons/godot_mcp/runtime/simulation_diagnostics.gd")
const Fixture = preload("res://examples/scripts/simulation_demo.gd")

func test_snapshot_filters_linked_records_and_stable_tick() -> void:
	var fixture := Fixture.new()
	var first := Diagnostics.read_adapter(fixture, {"sections": ["jobs", "inventories", "unknown"]})
	assert_true(first.ok)
	assert_eq(first.value.tick, 0)
	assert_eq(first.value.data.jobs[0].worker_id, first.value.data.inventories[0].entity_id)
	assert_eq(first.value.unsupported_sections, ["unknown"])
	assert_eq(Diagnostics.read_adapter(fixture, {"sections": ["jobs"], "entity_ids": ["missing"]}).value.data.jobs, [])
	assert_eq(fixture.tick, 0)
	assert_eq(Diagnostics.read_adapter(fixture, {}).value.data.size(), 6)
	fixture.free()

func test_missing_ambiguous_and_unsafe_adapters() -> void:
	var fixture := Fixture.new()
	assert_false(Diagnostics.select_adapter([]).ok)
	assert_false(Diagnostics.select_adapter([fixture, fixture]).ok)
	assert_true(Diagnostics.select_adapter([fixture]).ok)
	assert_false(Diagnostics.json_safe({"vector": Vector2.ZERO}))
	assert_false(Diagnostics.json_safe({"nan": NAN}))
	var cycle := []
	cycle.append(cycle)
	assert_false(Diagnostics.json_safe(cycle))
	cycle.clear()
	fixture.free()

func test_tick_result_requires_exact_numeric_increment() -> void:
	assert_true(Diagnostics.valid_tick_result({"ok": true, "tick": 3}, 3))
	for result in [{"ok": "true", "tick": 3}, {"ok": true, "tick": "3"}, {"ok": true, "tick": 4}, {"ok": false, "tick": 3}, {"ok": true, "tick": NAN}]:
		assert_false(Diagnostics.valid_tick_result(result, 3))

func test_safe_tick_boundary() -> void:
	assert_true(Diagnostics.safe_advance_range(9007199254740990, 1))
	assert_false(Diagnostics.safe_advance_range(9007199254740990, 2))
	assert_false(Diagnostics.safe_advance_range(9007199254740991, 1))
	assert_false(Diagnostics.valid_tick_result({"ok": true, "tick": 9007199254740992}, 9007199254740992))
