@tool
extends RefCounted
const Export = preload("res://addons/godot_mcp/runtime/export_support.gd")
const LogSanitizer = preload("res://addons/godot_mcp/runtime/log_sanitizer.gd")
const Snapshot = preload("res://addons/godot_mcp/runtime/project_snapshot.gd")
var records: Dictionary = {}
var active_id := ""
var _owner: WeakRef
var _copy
var _child_id := ""
var _cleanup := false
var _history: Array[String] = []
func _init(manager) -> void:
	_owner = weakref(manager)

func start(kind: String, options: Dictionary) -> Dictionary:
	var manager = _owner.get_ref()
	if manager.background_busy():
		return {"ok": false, "error": "A background job is active: " + manager.background_id}
	var id: String = manager.new_id()
	var directory: String = manager.artifact_dir(id)
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return {"ok": false, "error": "Could not create build artifact directory"}
	active_id = id
	manager.background_id = id
	records[id] = {"job_id": id, "kind": kind, "state": "running", "stage": "snapshot", "stages": [{"name": "snapshot", "state": "running"}], "diagnostics": [], "artifacts": [], "godot_version": Engine.get_version_info().string, "started_at": Time.get_datetime_string_from_system(true), "_started": Time.get_ticks_msec(), "_deadline": Time.get_ticks_msec() + int(options.timeout_seconds * 1000), "_directory": directory, "_snapshot": directory.path_join("project snapshot"), "_options": options.duplicate(true)}
	if kind == "export":
		records[id]["preset"] = options.preset
		records[id]["mode"] = options.mode
		records[id]["platform"] = options.platform
	_copy = Snapshot.new(ProjectSettings.globalize_path("res://").trim_suffix("/"), records[id]._snapshot, false, options.get("snapshot_keep_paths", []))
	_cleanup = false
	return status(id, kind)

func status(id: String, kind: String) -> Dictionary:
	if not records.has(id) or records[id].kind != kind:
		return {"ok": false, "error": "Unknown or expired " + kind + " job_id"}
	var out: Dictionary = records[id].duplicate(true)
	for key in out.keys():
		if str(key).begins_with("_"):
			out.erase(key)
	return {"ok": true, "value": out}

func poll() -> void:
	if active_id == "":
		return
	var job: Dictionary = records[active_id]
	var manager = _owner.get_ref()
	if _cleanup:
		_copy.poll()
		if _copy.done:
			if _copy.error != "":
				job.diagnostics.append({"stage": "cleanup", "severity": "warning", "message": _copy.error})
			_finalize()
		return
	if Time.get_ticks_msec() >= job._deadline:
		if _child_id != "" and manager.jobs.active(_child_id):
			manager.jobs.terminate(_child_id, "timeout")
			job["_timed_out"] = true
			return
		_finish(false, "Validation/build deadline exceeded", true)
		return
	if job.stage == "snapshot":
		_copy.poll()
		if not _copy.done:
			return
		if _copy.error != "" or Snapshot.disable_mcp(job._snapshot.path_join("project.godot")) != OK:
			_finish(false, _copy.error if _copy.error != "" else "Could not configure snapshot")
			return
		job.stages[-1].state = "passed"
		job.stages[-1]["files_copied"] = _copy.files_copied
		_launch_stage("import", PackedStringArray(["--headless", "--path", job._snapshot, "--editor", "--import"]))
		return
	if _child_id == "" or manager.jobs.active(_child_id):
		return
	var process: Dictionary = manager.jobs.records.get(_child_id, {})
	_retain_output(job, process)
	var code: Variant = process.get("exit_code")
	job["exit_code"] = code
	job.stages[-1]["exit_code"] = code
	_child_id = ""
	var report: Variant = null
	if job.stage == "startup":
		report = _startup_report(job)
	if code == null or code != 0 or process.get("engine_errors", false) or output_has_errors(process.get("output", [])):
		_finish(false, "Godot " + job.stage + " failed; inspect stage diagnostics")
		return
	job.stages[-1].state = "passed"
	if job.stage == "import":
		_after_import(job)
	elif job.stage == "export":
		var artifacts := Export.manifest(job._directory.path_join("output"), job._directory.path_join("output").path_join(job._options.filename))
		if not artifacts.ok:
			_finish(false, artifacts.error)
			return
		job.artifacts.append_array(artifacts.value)
		_finish(true, "")
	elif job.stage == "startup":
		if not report is Dictionary or not report.get("completed") is bool or not report.completed or not report.get("passed") is bool or not report.passed:
			_finish(false, "Startup exited early or did not produce a passing completion report")
			return
		_finish(true, "")

func _startup_report(job: Dictionary) -> Variant:
	var path: String = job._directory.path_join("startup.json")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 16 * 1024 * 1024:
		return null
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return null
	var report: Dictionary = LogSanitizer.clean_value(parser.data)
	job.artifacts.append({"path": path, "kind": "startup_report"})
	if report.get("diagnostics") is Array:
		for diagnostic in report.diagnostics.slice(0, 1000):
			if diagnostic is Dictionary:
				diagnostic["stage"] = "startup"
				job.diagnostics.append(diagnostic)
	while job.diagnostics.size() > 1000:
		job.diagnostics.pop_front()
	return report

func _after_import(job: Dictionary) -> void:
	if job.kind == "export":
		_start_export(job)
		return
	var scene: String = job._options.get("scene", "")
	if scene == "":
		var config := ConfigFile.new()
		if config.load(job._snapshot.path_join("project.godot")) == OK:
			scene = str(config.get_value("application", "run/main_scene", ""))
	if scene == "":
		_finish(false, "No main scene configured; supply scene")
		return
	_launch_stage("startup", PackedStringArray(["--headless", "--path", job._snapshot, "--script", "res://addons/godot_mcp/runtime/validation_bootstrap.gd", "--", "--scene", scene, "--seconds", str(job._options.startup_seconds), "--out", job._directory.path_join("startup.json")]))

func _launch_stage(stage: String, args: PackedStringArray) -> void:
	var manager = _owner.get_ref()
	var job: Dictionary = records[active_id]
	job.stage = stage
	job.stages.append({"name": stage, "state": "running"})
	_child_id = manager.new_id()
	var result: Dictionary = manager.jobs.launch(_child_id, OS.get_executable_path(), args, job.kind + ":" + stage)
	if not result.ok:
		_child_id = ""
		_finish(false, result.error)

func _retain_output(job: Dictionary, process: Dictionary) -> void:
	for diagnostic in sanitized_output(process.get("output", []), job._options.get("redactions", [])):
		diagnostic["stage"] = job.stage
		job.diagnostics.append(diagnostic)
	while job.diagnostics.size() > 1000:
		job.diagnostics.pop_front()
	var path: String = job._directory.path_join(job.stage + ".log.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(job.diagnostics.filter(func(entry): return entry.get("stage") == job.stage)))
		file.close()
		job.artifacts.append({"path": path, "kind": "stage_log"})

static func output_has_errors(output: Array) -> bool:
	var text := ""
	for entry in output:
		text += str(entry.get("text", ""))
	return text.begins_with("ERROR:") or text.begins_with("SCRIPT ERROR:") or "\nERROR:" in text or "\nSCRIPT ERROR:" in text

func _finish(passed: bool, message: String, timed_out: bool = false) -> void:
	var job: Dictionary = records[active_id]
	if _child_id != "":
		_retain_output(job, _owner.get_ref().jobs.records.get(_child_id, {}))
		_child_id = ""
	job.stages[-1].state = "passed" if passed else ("timed_out" if timed_out else "failed")
	job["passed"] = passed
	job["_terminal_state"] = "completed" if passed else ("timed_out" if timed_out else "failed")
	if message != "":
		job.diagnostics.append({"stage": job.stage, "severity": "error", "message": message})
	job.stage = "cleanup"
	_copy.close()
	_copy = Snapshot.new(job._snapshot, "", true)
	_cleanup = true

func _finalize() -> void:
	var job: Dictionary = records[active_id]
	job.state = job._terminal_state
	job["duration_ms"] = Time.get_ticks_msec() - int(job._started)
	job["ended_at"] = Time.get_datetime_string_from_system(true)
	var path: String = job._directory.path_join("result.json")
	job.artifacts.append({"path": path, "kind": "result"})
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(status(active_id, job.kind).value))
		file.close()
	_history.append(active_id)
	active_id = ""
	_copy = null
	while _history.size() > 20:
		records.erase(_history.pop_front())

func shutdown() -> void:
	if active_id == "":
		return
	if _child_id != "":
		_owner.get_ref().jobs.terminate(_child_id, "plugin_disabled")
	if _copy != null:
		_copy.close()
	# Retain unfinished snapshot on plugin shutdown rather than race a live child.
	# No source-project files are changed; normal terminal paths remove the copy.
	active_id = ""

func _start_export(job: Dictionary) -> void:
	var output: String = job._directory.path_join("output")
	if DirAccess.make_dir_recursive_absolute(output) != OK:
		_finish(false, "Could not create export output directory")
		return
	# Godot keeps signing/encryption credentials outside export_presets.cfg.
	# Copy only this saved file into the isolated cache; never report its contents.
	var credentials := ProjectSettings.globalize_path("res://.godot/export_credentials.cfg")
	if FileAccess.file_exists(credentials):
		if DirAccess.copy_absolute(credentials, job._snapshot.path_join(".godot/export_credentials.cfg")) != OK:
			_finish(false, "Could not copy saved export credentials into snapshot")
			return
		var config := ConfigFile.new()
		if config.load(credentials) == OK:
			for section in config.get_sections():
				for key in config.get_section_keys(section):
					var secret: Variant = config.get_value(section, key)
					if secret is String and secret != "":
						job._options.redactions.append(secret)
	_launch_stage("export", Export.arguments(job._snapshot, job._options.preset, job._options.mode, output.path_join(job._options.filename)))

static func clean_log(text: String) -> String:
	return LogSanitizer.clean_log(text)

static func sanitized_output(output: Array, secrets: Array) -> Array:
	# Pipe reads are arbitrary chunks. Reassemble each stream before redacting,
	# including when stdout/stderr reads were interleaved by the process poller.
	var streams := {}
	for entry in output:
		var source: String = str(entry.get("source", "stdout"))
		if not streams.has(source):
			streams[source] = {"source": source, "text": "", "timestamp_msec": entry.get("timestamp_msec"), "sequence": entry.get("sequence")}
		streams[source].text += str(entry.get("text", ""))
		streams[source]["last_timestamp_msec"] = entry.get("timestamp_msec")
	var result := []
	for stream in streams.values():
		var text := clean_log(stream.text)
		for secret in secrets:
			if secret is String and secret != "":
				text = text.replace(secret, "[REDACTED]")
		stream["truncated"] = text.length() > 512 * 1024
		stream.text = text.left(512 * 1024)
		result.append(stream)
	return result
