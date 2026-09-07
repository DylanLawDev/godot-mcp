@tool
extends RefCounted
const Paths = preload("res://addons/godot_mcp/utils/paths.gd")
var _manager

func _init(manager = null) -> void:
	_manager = manager

func manager():
	if _manager != null:
		return _manager
	return Engine.get_meta("GodotMCPRuntime", null)

static func failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}

static func integer(value: Variant, low: int, high: int) -> bool:
	return (typeof(value) == TYPE_INT or (typeof(value) == TYPE_FLOAT and is_finite(value) and value == floor(value))) and value >= low and value <= high

func run_project(args: Dictionary) -> Dictionary:
	var runtime = manager()
	if runtime == null:
		return failure("Runtime manager requires an enabled editor plugin")
	var headless: Variant = args.get("headless", false)
	var timeout_value: Variant = args.get("startup_timeout_seconds", 15)
	if not headless is bool:
		return failure("headless must be a boolean")
	if not integer(timeout_value, 1, 120):
		return failure("startup_timeout_seconds must be an integer from 1 to 120")
	var scene: Variant = args.get("scene", ProjectSettings.get_setting("application/run/main_scene", ""))
	if not scene is String or scene.strip_edges() == "":
		return failure("No main scene configured; provide scene")
	if scene.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(scene)
		if not ResourceUID.has_id(uid):
			return failure("Unknown scene UID: " + scene)
		scene = ResourceUID.get_id_path(uid)
	if scene.is_absolute_path() and not scene.begins_with("res://"):
		return failure("scene must be a project-relative or res:// path")
	var checked := Paths.validate(scene)
	if not checked.ok:
		return failure(checked.error)
	if not ResourceLoader.exists(checked.path, "PackedScene"):
		return failure("Scene does not exist: " + checked.path)
	var resource := ResourceLoader.load(checked.path, "PackedScene")
	if not resource is PackedScene:
		return failure("Resource is not a PackedScene: " + checked.path)
	return runtime.launch(checked.path, headless, float(timeout_value))

func register_tools(reg) -> void:
	reg.register("run_project", "Launch saved main scene or explicit scene in a managed standalone game. Returns a starting session ID; poll get_run_status for readiness.",
		{"type": "object", "properties": {"scene": {"type": "string"}, "headless": {"type": "boolean", "default": false}, "startup_timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 120, "default": 15}}}, Callable(self, "run_project"))
