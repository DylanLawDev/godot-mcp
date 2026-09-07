@tool
extends RefCounted
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const Paths = preload("res://addons/godot_mcp/utils/paths.gd")
const RuntimeTools = preload("res://addons/godot_mcp/tools/runtime_tools.gd")
var _manager

func _init(manager = null) -> void:
	_manager = manager

func manager():
	return _manager if _manager != null else Engine.get_meta("GodotMCPRuntime", null)

func run_scenario(args: Dictionary) -> Dictionary:
	var runtime = manager()
	if runtime == null:
		return {"ok": false, "error": "Runtime manager requires an enabled editor plugin"}
	if not args.get("scenario_path") is String or not args.get("render", false) is bool or not RuntimeTools.integer(args.get("timeout_seconds", 60), 1, 3600):
		return {"ok": false, "error": "Expected scenario_path, boolean render and timeout_seconds from 1 to 3600"}
	var checked := Paths.validate(args.scenario_path)
	if not checked.ok:
		return checked
	var file := FileAccess.open(checked.path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Scenario file not found: " + checked.path}
	if file.get_length() > 4 * 1024 * 1024:
		return {"ok": false, "error": "Scenario JSON exceeds 4 MiB"}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
		return {"ok": false, "error": "Scenario must be a valid JSON object"}
	if runtime.background_id != "" and runtime.jobs.active(runtime.background_id):
		return {"ok": false, "error": "A background job is active: " + runtime.background_id}
	var id := Sessions.new_id()
	var directory := Sessions.artifact_dir(id)
	var prepared := prepare_scenario(json.data, directory)
	if not prepared.ok:
		return prepared
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return {"ok": false, "error": "Could not create scenario artifact directory"}
	var execution_path := directory.path_join("scenario.json")
	var output_path := directory.path_join("result.json")
	var execution := FileAccess.open(execution_path, FileAccess.WRITE)
	if execution == null:
		return {"ok": false, "error": "Could not write execution scenario"}
	execution.store_string(JSON.stringify(prepared.value, "  "))
	execution.close()
	var command := PackedStringArray(["--path", ProjectSettings.globalize_path("res://")])
	if not args.get("render", false):
		command.append("--headless")
	command.append_array(PackedStringArray(["--script", "res://addons/godot_mcp/runtime/scenario_runner.gd", "--", "--scenario", execution_path, "--out", output_path]))
	var launched: Dictionary = runtime.launch_job("scenario", command, float(args.get("timeout_seconds", 60)), id)
	if not launched.ok:
		return launched
	runtime.jobs.records[id]["result_path"] = output_path
	runtime.jobs.records[id]["source_scenario"] = checked.path
	return {"ok": true, "value": {"scenario_id": id, "state": "running", "result_path": output_path}}

static func prepare_scenario(source: Dictionary, directory: String) -> Dictionary:
	if not source.get("scene") is String or not source.get("steps", []) is Array:
		return {"ok": false, "error": "Scenario requires scene and an array of steps"}
	var scene := Paths.validate(source.scene)
	if not scene.ok:
		return scene
	if not ResourceLoader.exists(scene.path, "PackedScene"):
		return {"ok": false, "error": "Scenario scene not found: " + scene.path}
	var result := source.duplicate(true)
	result.scene = scene.path
	var remapped := {}
	for step in result.get("steps", []):
		if not step is Dictionary:
			return {"ok": false, "error": "Every scenario step must be an object"}
		var field := ""
		var texture: bool = step.get("type") == "capture_texture"
		if texture:
			field = "out"
		elif step.get("type") == "capture_frames" or (step.get("type") == "step_frames" and step.has("dir")):
			field = "dir"
		if field != "":
			if not step.get(field) is String or step[field].strip_edges() == "":
				return {"ok": false, "error": "Capture output must be a nonempty string"}
			var key: String = field + ":" + step[field]
			if not remapped.has(key):
				remapped[key] = directory.path_join("texture_%d.png" % remapped.size() if texture else "frames_%d" % remapped.size())
			step[field] = remapped[key]
	return {"ok": true, "value": result}

func register_tools(reg) -> void:
	reg.register("get_scenario_result", "Poll a scenario job and retrieve original assertions/logs/capture manifests after exit. Infrastructure failures remain distinct from failed assertions; reads are stable and non-destructive.",
		{"type": "object", "properties": {"scenario_id": {"type": "string"}}, "required": ["scenario_id"]}, Callable(self, "get_scenario_result"))
	reg.register("run_scenario", "Run a saved scenario asynchronously using the existing runner. Returns scenario_id for get_scenario_result; capture outputs are isolated in a managed artifact directory.",
		{"type": "object", "properties": {"scenario_path": {"type": "string"}, "render": {"type": "boolean", "default": false}, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 3600, "default": 60}}, "required": ["scenario_path"]}, Callable(self, "run_scenario"))

func get_scenario_result(args: Dictionary) -> Dictionary:
	var runtime = manager()
	if runtime == null:
		return {"ok": false, "error": "Runtime manager requires an enabled editor plugin"}
	var id: Variant = args.get("scenario_id")
	if not id is String or id == "" or not runtime.jobs.records.has(id) or runtime.jobs.records[id].kind != "scenario":
		return {"ok": false, "error": "Unknown or expired scenario_id"}
	var job: Dictionary = runtime.jobs.records[id]
	var value := {"scenario_id": id, "state": "running", "exit_code": job.get("exit_code"), "artifacts": [], "diagnostics": job.get("output", []).duplicate(true), "result_path": job.get("result_path", "")}
	if runtime.jobs.active(id):
		return {"ok": true, "value": value}
	# Parse once, only after the child has exited and its pipes are drained.
	if not job.has("scenario_result"):
		job["scenario_result"] = _read_completed_result(job)
	return {"ok": true, "value": job.scenario_result.duplicate(true)}

static func _read_completed_result(job: Dictionary) -> Dictionary:
	var value := {"scenario_id": job.id, "state": "failed", "passed": false, "exit_code": job.get("exit_code"), "artifacts": [], "diagnostics": job.get("output", []).duplicate(true), "result_path": job.get("result_path", "")}
	if job.get("termination_reason") == "timeout":
		value.state = "timed_out"
		value["error"] = "Scenario process exceeded its timeout"
		return value
	var file := FileAccess.open(value.result_path, FileAccess.READ)
	if file == null:
		value["error"] = "Scenario exited without a readable result file"
		return value
	if file.get_length() > 32 * 1024 * 1024:
		value["error"] = "Result exceeds 32 MiB inspection limit; inspect result_path"
		return value
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
		value["error"] = "Malformed scenario result JSON"
		return value
	var result: Dictionary = json.data
	if not result.get("passed") is bool or not result.get("steps") is Array or not result.get("assertions") is Array:
		value["error"] = "Invalid scenario result structure"
		return value
	value["result"] = result
	var expected_code := 0 if result.passed else 1
	if job.get("exit_code") == expected_code and result.get("ok", true):
		value.state = "completed"
		value.passed = result.passed
	else:
		value["error"] = "Runner failed or exit status disagrees with its result"
	var scanned := _artifact_manifest(job.get("artifact_dir", ""), result)
	value.artifacts = scanned.artifacts
	if scanned.error != "":
		value["error"] = scanned.error
		value.state = "failed"
		value.passed = false
	value["artifacts_truncated"] = scanned.truncated
	if JSON.stringify(value).to_utf8_buffer().size() > 4 * 1024 * 1024:
		value.erase("result")
		value["result_omitted"] = "Inline result exceeds 4 MiB; inspect result_path"
	return value

static func _artifact_manifest(directory: String, result: Dictionary) -> Dictionary:
	var artifacts := []
	var seen := {}
	var pending := [directory]
	var error := ""
	var visited := 0
	while not pending.is_empty() and artifacts.size() < 1000 and visited < 2000:
		var current: String = pending.pop_back()
		visited += 1
		var dir := DirAccess.open(current)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "" and artifacts.size() < 1000:
			var path := current.path_join(name)
			if not dir.is_link(name):
				if dir.current_is_dir():
					pending.append(path)
				elif name.get_extension().to_lower() == "png":
					var entry := {"file": path, "exists": true, "mime_type": "image/png"}
					var image := FileAccess.open(path, FileAccess.READ)
					if image != null and image.get_length() >= 24:
						entry["size_bytes"] = image.get_length()
						image.big_endian = true
						image.seek(16)
						entry["width"] = image.get_32()
						entry["height"] = image.get_32()
					artifacts.append(entry)
					seen[path] = true
			name = dir.get_next()
		dir.list_dir_end()
	var manifests: Variant = result.get("captures", [])
	if not manifests is Array:
		return {"artifacts": artifacts, "error": "Invalid capture manifest", "truncated": false}
	for manifest in manifests:
		if not manifest is Dictionary or not manifest.get("frames", []) is Array:
			error = "Invalid capture manifest"
			break
		for frame in manifest.get("frames", []):
			if not frame is Dictionary:
				error = "Invalid frame manifest"
				break
			if not frame.has("file"):
				continue # Original per-frame capture errors remain in result.
			if not frame.file is String or not _contained(frame.file, directory):
				error = "Capture manifest references a file outside the job directory"
				break
			if not seen.has(frame.file) and artifacts.size() < 1000:
				artifacts.append({"file": frame.file, "exists": FileAccess.file_exists(frame.file), "width": frame.get("width"), "height": frame.get("height")})
	return {"artifacts": artifacts, "error": error, "truncated": artifacts.size() >= 1000 or not pending.is_empty()}

static func _contained(path: String, directory: String) -> bool:
	var normalized := path.replace("\\", "/").simplify_path()
	var base := directory.replace("\\", "/").simplify_path().trim_suffix("/")
	if not normalized.begins_with(base + "/"):
		return false
	var current := base
	for component in normalized.substr(base.length() + 1).split("/"):
		var dir := DirAccess.open(current)
		if dir != null and dir.is_link(component):
			return false
		current = current.path_join(component)
	return true
