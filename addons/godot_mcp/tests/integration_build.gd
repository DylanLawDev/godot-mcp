extends SceneTree
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const Tools = preload("res://addons/godot_mcp/tools/build_tools.gd")
var manager
var failures := []
func _initialize() -> void:
	manager = Sessions.new()
	_main.call_deferred()
func _main() -> void:
	var tools := Tools.new(manager)
	var expected := OS.get_cmdline_user_args()[0]
	var source_hash := FileAccess.get_sha256("res://project.godot")
	var launched := tools.validate_project({"startup_seconds": 1, "timeout_seconds": 1 if expected == "timed_out" else 30})
	if not launched.ok:
		failures.append(launched)
		_finish()
		return
	var id: String = launched.value.job_id
	if tools.validate_project({}).ok or tools.validate_project({"job_id": id, "scene": "bad"}).ok or tools.validate_project({"job_id": "unknown"}).ok:
		failures.append("job isolation/argument validation failed")
	var result := tools.validate_project({"job_id": id})
	var deadline := Time.get_ticks_msec() + 40000
	while result.value.state == "running" and Time.get_ticks_msec() < deadline:
		manager.poll()
		await process_frame
		result = tools.validate_project({"job_id": id})
	if result.value.state != expected:
		failures.append(result)
	if FileAccess.get_sha256("res://project.godot") != source_hash or DirAccess.dir_exists_absolute(manager.build_jobs.records[id]._snapshot):
		failures.append("source changed or snapshot not removed")
	if expected == "failed" and result.value.diagnostics.is_empty():
		failures.append("failure omitted diagnostics")
	if tools.validate_project({"job_id": id}) != result:
		failures.append("polling changed retained result")
	print("BUILD RESULT: ", JSON.stringify(result))
	_finish()
func _finish() -> void:
	manager.shutdown()
	print("BUILD INTEGRATION: ", failures)
	quit(0 if failures.is_empty() else 1)
