@tool
extends SceneTree

# Headless scenario runner. Launch:
#   godot4 --headless --path . --script addons/godot_mcp/runtime/scenario_runner.gd \
#          -- --scenario <path> --out <path>
# Loads the scenario's scene, pumps physics frames while delegating steps to
# scenario_engine.gd, writes a results JSON, and exits 0 iff all assertions passed.

const ScenarioEngine = preload("res://addons/godot_mcp/runtime/scenario_engine.gd")
const OutputCapture = preload("res://addons/godot_mcp/tools/output_capture.gd")

func _initialize() -> void:
	var args := _parse_args()
	if not args.has("scenario") or not args.has("out"):
		push_error("scenario_runner: --scenario <path> --out <path> required")
		quit(2)
		return
	# Run the loop as a coroutine; it resumes on physics_frame and quits when done.
	_main(args["scenario"], args["out"])

func _parse_args() -> Dictionary:
	var out := {}
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		var a := str(argv[i])
		if a == "--scenario" and i + 1 < argv.size():
			out["scenario"] = str(argv[i + 1])
			i += 2
		elif a == "--out" and i + 1 < argv.size():
			out["out"] = str(argv[i + 1])
			i += 2
		else:
			i += 1
	return out

func _main(scenario_path: String, out_path: String) -> void:
	var logger := OutputCapture.new()
	# Held for this one-shot process's lifetime; intentionally not paired with OS.remove_logger like editor-resident call sites.
	OS.add_logger(logger)

	var parsed := _load_scenario(scenario_path)
	if not parsed["ok"]:
		_write_results(out_path, _fail_results("", parsed["error"], logger))
		quit(2)
		return
	var scenario: Dictionary = parsed["value"]
	var scene_path := str(scenario.get("scene", ""))

	var packed = load(scene_path)
	if packed == null or not (packed is PackedScene):
		_write_results(out_path, _fail_results(scene_path, "Could not load scene: " + scene_path, logger))
		quit(2)
		return

	var inst: Node = (packed as PackedScene).instantiate()
	root.add_child(inst)
	current_scene = inst
	await physics_frame  # let _enter_tree/_ready settle

	var eng := ScenarioEngine.new()
	eng.set_root(inst)
	var frames_run := 0
	for step in scenario.get("steps", []):
		var res: Dictionary = eng.execute(step)
		if res.has("frames"):
			for _i in int(res["frames"]):
				await physics_frame
				frames_run += 1
		if res.has("follow_up"):
			for _j in int(res.get("follow_up_after_frames", 1)):
				await physics_frame
				frames_run += 1
			eng.execute(res["follow_up"])
		if res.get("fatal", false):
			break

	var out := eng.results()
	out["scene"] = scene_path
	out["frames_run"] = frames_run
	out["errors"] = _errors(logger)
	out["log"] = _log_tail(logger)
	var wrote := _write_results(out_path, out)
	if not wrote:
		quit(2)
		return
	quit(0 if out.get("passed", false) else 1)

func _load_scenario(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "Scenario file not found: " + path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Could not open scenario: " + path}
	var text := f.get_as_text()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok": false, "error": "Invalid scenario JSON: " + json.get_error_message()}
	if typeof(json.data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "Scenario root must be a JSON object"}
	return {"ok": true, "value": json.data}

func _fail_results(scene: String, error: String, logger) -> Dictionary:
	return {
		"ok": false, "passed": false, "scene": scene, "frames_run": 0,
		"steps": [], "assertions": [], "errors": _errors(logger),
		"log": _log_tail(logger), "error": error,
	}

func _errors(logger) -> Array:
	return logger.entries(0, true)

func _log_tail(logger) -> Array:
	return logger.entries(200, false)

func _write_results(path: String, data: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("scenario_runner: could not write results to " + path)
		return false
	f.store_string(JSON.stringify(data, "  "))
	f.flush()
	return true
