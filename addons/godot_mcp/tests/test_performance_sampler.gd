extends "res://addons/godot_mcp/tests/test_case.gd"
const Sampler = preload("res://addons/godot_mcp/runtime/performance_sampler.gd")
func test_summary() -> void:
	var samples := []
	for n in range(1, 21):
		samples.append({"values": {"metric": n}})
	var result: Dictionary = Sampler.summarize(samples).metric
	assert_eq(result.count, 20)
	assert_eq(result.min, 1.0)
	assert_eq(result.max, 20.0)
	assert_eq(result.mean, 10.5)
	assert_eq(result.p95, 19.0)
func test_limits() -> void:
	assert_eq(Sampler.validate({}), "")
	for args in [{"duration_seconds": "2"}, {"duration_seconds": NAN}, {"duration_seconds": 31}, {"interval_ms": 15}, {"interval_ms": 16.5}, {"custom_monitors": [false]}]:
		assert_true(Sampler.validate(args) != "")

func test_long_monitor_names_respect_wire_budget() -> void:
	var values := {}
	for i in 64:
		values[str(i) + "界".repeat(250)] = 1.0
	var samples := []
	var budget := {"bytes": 2}
	for i in 2000:
		if not Sampler.append_bounded(samples, {"elapsed_ms": i, "values": values}, budget):
			break
	assert_true(samples.size() > 1 and samples.size() < 2000)
	assert_true(JSON.stringify(samples).to_utf8_buffer().size() <= Sampler.MAX_SAMPLE_BYTES)
