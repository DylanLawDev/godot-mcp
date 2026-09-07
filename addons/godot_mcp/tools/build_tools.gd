@tool
extends RefCounted
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
func register_tools(reg) -> void:
	reg.register("validate_project", "Validate saved project imports and bounded scene startup in a temporary copy. Start with optional scene/startup_seconds/timeout_seconds; poll with job_id alone. Does not validate all gameplay or unsaved changes.",
		{"type": "object", "properties": {"job_id": {"type": "string"}, "scene": {"type": "string"}, "startup_seconds": {"type": "integer", "minimum": 1, "maximum": 30, "default": 3}, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 1800, "default": 120}}, "oneOf": [{"required": ["job_id"], "maxProperties": 1}, {"not": {"required": ["job_id"]}}]}, Callable(self, "validate_project"))
