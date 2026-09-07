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
