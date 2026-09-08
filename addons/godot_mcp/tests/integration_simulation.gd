extends SceneTree
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const Tools = preload("res://addons/godot_mcp/tools/runtime_tools.gd")
var manager
var failures := []
func _initialize() -> void:
	manager = Sessions.new()
	_main.call_deferred()
func _main() -> void:
	var tools := Tools.new(manager)
	var launched := tools.run_project({"scene": "res://examples/scenes/simulation_demo.tscn", "headless": true})
	if not launched.ok:
		failures.append(launched)
		_finish()
		return
	var id: String = launched.value.session_id
	var deadline := Time.get_ticks_msec() + 15000
	while manager.summary(id).state == "starting" and Time.get_ticks_msec() < deadline:
		manager.poll()
		await process_frame
	var snapshot = tools.get_simulation_snapshot({"session_id": id})
	while not snapshot.done:
		manager.poll()
		await process_frame
	if not snapshot.value.ok or snapshot.value.value.tick != 0 or snapshot.value.value.data.jobs[0].worker_id != "settler-1":
		failures.append(snapshot.value)
	for ticks in [1, 100]:
		var advanced = tools.advance_ticks({"session_id": id, "ticks": ticks})
		while not advanced.done:
			manager.poll()
			await process_frame
		if not advanced.value.ok or advanced.value.value.advanced_ticks != ticks:
			failures.append(advanced.value)
	for _i in 10:
		manager.poll()
		await process_frame
	var after = tools.get_simulation_snapshot({"session_id": id})
	while not after.done:
		manager.poll()
		await process_frame
	if not after.value.ok or after.value.value.tick != 101 or after.value.value.data.inventories[0].items.wood != 101:
		failures.append("simulation ticks diverged from the exact requested count")
	var large = tools.advance_ticks({"session_id": id, "ticks": 10000})
	var overlapping = tools.advance_ticks({"session_id": id, "ticks": 1})
	while not large.done or not overlapping.done:
		manager.poll()
		await process_frame
	if not large.value.ok or overlapping.value.ok:
		failures.append("concurrent simulation advancement was not rejected")
	var stop = tools.stop_project({"session_id": id})
	while not stop.done:
		manager.poll()
		await process_frame
	await _failure_case(tools)
	_finish()
func _finish() -> void:
	manager.shutdown()
	print("SIMULATION INTEGRATION: ", failures)
	quit(0 if failures.is_empty() else 1)

func _failure_case(tools) -> void:
	var launched: Dictionary = tools.run_project({"scene": "res://addons/godot_mcp/tests/fixtures/simulation_failure.tscn", "headless": true})
	if not launched.ok:
		failures.append(launched)
		return
	var id: String = launched.value.session_id
	var deadline := Time.get_ticks_msec() + 15000
	while manager.summary(id).state == "starting" and Time.get_ticks_msec() < deadline:
		manager.poll()
		await process_frame
	var advance = tools.advance_ticks({"session_id": id, "ticks": 5})
	while not advance.done:
		manager.poll()
		await process_frame
	if advance.value.ok:
		failures.append("injected tick failure unexpectedly succeeded")
	else:
		var detail: Variant = JSON.parse_string(advance.value.error)
		if not detail is Dictionary or detail.get("advanced_ticks") != 2 or detail.get("tick_after") != 2 or not str(detail.get("message", "")).contains("Injected fixture tick failure"):
			failures.append("partial tick count was not preserved")
	var stop = tools.stop_project({"session_id": id})
	while not stop.done:
		manager.poll()
		await process_frame
