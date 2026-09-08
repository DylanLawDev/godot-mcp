@tool
extends RefCounted
const Export = preload("res://addons/godot_mcp/runtime/export_support.gd")
const Paths = preload("res://addons/godot_mcp/utils/paths.gd")
const RuntimeTools = preload("res://addons/godot_mcp/tools/runtime_tools.gd")
var _manager
func _init(manager = null) -> void:
	_manager = manager
func manager():
	return _manager if _manager != null else Engine.get_meta("GodotMCPRuntime", null)
func validate_project(args: Dictionary) -> Dictionary:
	var runtime = manager()
	if runtime == null:
		return {"ok": false, "error": "Runtime manager requires an enabled editor plugin"}
	if args.has("job_id"):
		if args.size() != 1 or not args.job_id is String or args.job_id == "":
			return {"ok": false, "error": "Poll with only a nonempty job_id"}
		return runtime.build_jobs.status(args.job_id, "validation")
	if not RuntimeTools.integer(args.get("startup_seconds", 3), 1, 30) or not RuntimeTools.integer(args.get("timeout_seconds", 120), 1, 1800):
		return {"ok": false, "error": "startup_seconds must be 1–30; timeout_seconds must be 1–1800"}
	var options := {"startup_seconds": args.get("startup_seconds", 3), "timeout_seconds": args.get("timeout_seconds", 120)}
	if args.has("scene"):
		if not args.scene is String or args.scene == "":
			return {"ok": false, "error": "scene must be a nonempty project-relative path"}
		var checked := Paths.validate(args.scene)
		if not checked.ok:
			return checked
		options["scene"] = checked.path
	return runtime.build_jobs.start("validation", options)
func export_build(args: Dictionary) -> Dictionary:
	var runtime = manager()
	if runtime == null:
		return {"ok": false, "error": "Runtime manager requires an enabled editor plugin"}
	if args.has("job_id"):
		if args.size() != 1 or not args.job_id is String or args.job_id == "":
			return {"ok": false, "error": "Poll with only a nonempty job_id"}
		return runtime.build_jobs.status(args.job_id, "export")
	if not args.get("preset") is String or args.preset == "" or args.get("mode", "debug") not in ["debug", "release"] or not RuntimeTools.integer(args.get("timeout_seconds", 600), 1, 3600):
		return {"ok": false, "error": "Expected preset, mode debug/release and timeout_seconds 1–3600"}
	if runtime.background_busy():
		return {"ok": false, "error": "A background job is active: " + runtime.background_id}
	var prepared := Export.prepare(args.preset, args.get("mode", "debug"), ProjectSettings.globalize_path("res://").trim_suffix("/"))
	if not prepared.ok:
		return prepared
	prepared.value["timeout_seconds"] = args.get("timeout_seconds", 600)
	return runtime.build_jobs.start("export", prepared.value)

func register_tools(reg) -> void:
	reg.register("export_build", "Export a saved project copy using an existing desktop preset and installed templates. Start with preset/mode/timeout_seconds; poll with job_id alone. Returns managed artifacts; does not execute, publish or install anything.",
		{"type": "object", "properties": {"job_id": {"type": "string"}, "preset": {"type": "string"}, "mode": {"type": "string", "enum": ["debug", "release"], "default": "debug"}, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 3600, "default": 600}}, "oneOf": [{"required": ["job_id"], "maxProperties": 1}, {"required": ["preset"], "not": {"required": ["job_id"]}}]}, Callable(self, "export_build"))
	reg.register("validate_project", "Validate saved project imports and bounded scene startup in a temporary copy. Start with optional scene/startup_seconds/timeout_seconds; poll with job_id alone. Does not validate all gameplay or unsaved changes.",
		{"type": "object", "properties": {"job_id": {"type": "string"}, "scene": {"type": "string"}, "startup_seconds": {"type": "integer", "minimum": 1, "maximum": 30, "default": 3}, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 1800, "default": 120}}, "oneOf": [{"required": ["job_id"], "maxProperties": 1}, {"not": {"required": ["job_id"]}}]}, Callable(self, "validate_project"))
