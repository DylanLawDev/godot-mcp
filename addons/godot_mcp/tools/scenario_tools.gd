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
	reg.register("run_scenario", "Run a saved scenario asynchronously using the existing runner. Returns scenario_id for get_scenario_result; capture outputs are isolated in a managed artifact directory.",
		{"type": "object", "properties": {"scenario_path": {"type": "string"}, "render": {"type": "boolean", "default": false}, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 3600, "default": 60}}, "required": ["scenario_path"]}, Callable(self, "run_scenario"))
