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
	var source_hash := FileAccess.get_sha256("res://export_presets.cfg")
	var mode := OS.get_cmdline_user_args()[0]
	var launched := tools.export_build({"preset": "Linux Fixture", "mode": mode, "timeout_seconds": 90})
	if not launched.ok:
		failures.append(launched)
		_finish()
		return
	var id: String = launched.value.job_id
	if tools.export_build({"preset": "Linux Fixture"}).ok or tools.validate_project({}).ok or tools.validate_project({"job_id": id}).ok:
		failures.append("background lane or job kind isolation failed")
	var result := tools.export_build({"job_id": id})
	while result.value.state == "running":
		manager.poll()
		await process_frame
		result = tools.export_build({"job_id": id})
	if result.value.state != "completed" or not result.value.passed:
		failures.append(result)
	var binaries := 0
	for artifact in result.value.artifacts:
		if artifact.kind == "package":
			binaries += 1
			var file := FileAccess.open(artifact.path, FileAccess.READ)
			if file == null or file.get_buffer(4) != PackedByteArray([127, 69, 76, 70]):
				failures.append("exported Linux package is not an ELF binary")
	if binaries != 1:
		failures.append("expected exactly one package")
	if source_hash != FileAccess.get_sha256("res://export_presets.cfg") or DirAccess.dir_exists_absolute(manager.build_jobs.records[id]._snapshot):
		failures.append("preset changed or snapshot not cleaned")
	print("EXPORT ARTIFACTS: ", JSON.stringify(result.value.artifacts))
	_finish()
func _finish() -> void:
	manager.shutdown()
	print("EXPORT INTEGRATION: ", failures)
	quit(0 if failures.is_empty() else 1)
