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
	var stop = tools.stop_project({"session_id": id})
	while not stop.done:
		manager.poll()
		await process_frame
	_finish()
func _finish() -> void:
	manager.shutdown()
	print("SIMULATION INTEGRATION: ", failures)
	quit(0 if failures.is_empty() else 1)
