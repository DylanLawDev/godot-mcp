@tool
extends RefCounted
const InputSequence = preload("res://addons/godot_mcp/runtime/input_sequence.gd")
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

func get_run_status(args: Dictionary) -> Dictionary:
	var runtime = manager()
	if runtime == null:
		return failure("Runtime manager requires an enabled editor plugin")
	var id: Variant = args.get("session_id", runtime.active_id if runtime.active_id != "" else runtime.latest_id)
	if not id is String or (args.has("session_id") and id == ""):
		return failure("session_id must be a nonempty string")
	if id == "":
		return {"ok": true, "value": {"state": "idle", "session_id": null}}
	var status: Dictionary = runtime.summary(id)
	if status.is_empty():
		return failure("Unknown or expired session: " + id)
	return {"ok": true, "value": status}

func stop_project(args: Dictionary) -> Variant:
	var runtime = manager()
	if runtime == null:
		return failure("Runtime manager requires an enabled editor plugin")
	var id: Variant = args.get("session_id")
	var grace: Variant = args.get("grace_seconds", 2)
	if not id is String or id == "":
		return failure("session_id must be a nonempty string")
	if not (typeof(grace) in [TYPE_INT, TYPE_FLOAT]) or not is_finite(float(grace)) or grace < 0 or grace > 10:
		return failure("grace_seconds must be a number from 0 to 10")
	return runtime.stop_session(id, float(grace))

func capture_game_frame(args: Dictionary) -> Variant:
	var runtime = manager()
	if runtime == null:
		return failure("Runtime manager requires an enabled editor plugin")
	var id: Variant = args.get("session_id")
	if not id is String or id == "":
		return failure("session_id must be a nonempty string")
	if not integer(args.get("downscale", 1), 1, 16):
		return failure("downscale must be an integer from 1 to 16")
	if args.get("format", "file") not in ["file", "base64"]:
		return failure("format must be file or base64")
	return runtime.request(id, "capture_game_frame", {"downscale": args.get("downscale", 1), "format": args.get("format", "file")})

func send_input(args: Dictionary) -> Variant:
	var runtime = manager()
	if runtime == null:
		return failure("Runtime manager requires an enabled editor plugin")
	var id: Variant = args.get("session_id")
	if not id is String or id == "":
		return failure("session_id must be a nonempty string")
	var events: Variant = args.get("events")
	if not events is Array or events.is_empty() or events.size() > 256:
		return failure("events must contain 1–256 objects")
	# Full validation runs in the game, whose InputMap is authoritative.
	var tick_rate := float(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60))
	var timeout := InputSequence.timeout_for_events(events, tick_rate) + 5.0
	return runtime.request(id, "send_input", {"events": events}, timeout)

func resize_game_window(args: Dictionary) -> Variant:
	var runtime = manager()
	if runtime == null:
		return failure("Runtime manager requires an enabled editor plugin")
	var id: Variant = args.get("session_id")
	if not id is String or id == "":
		return failure("session_id must be a nonempty string")
	if not integer(args.get("width"), 64, 8192) or not integer(args.get("height"), 64, 8192):
		return failure("width and height must be integers from 64 to 8192")
	return runtime.request(id, "resize_game_window", {"width": args.width, "height": args.height})

func get_runtime_tree(args: Dictionary) -> Variant:
	var runtime = manager()
	if runtime == null:
		return failure("Runtime manager requires an enabled editor plugin")
	var id: Variant = args.get("session_id")
	if not id is String or id == "":
		return failure("session_id must be a nonempty string")
	if not args.get("path", ".") is String:
		return failure("path must be a string relative to the current scene")
	if not integer(args.get("max_depth", 8), 0, 64) or not integer(args.get("max_nodes", 1000), 1, 10000):
		return failure("max_depth must be 0–64 and max_nodes must be 1–10000")
	return runtime.request(id, "get_runtime_tree", {"path": args.get("path", "."), "max_depth": args.get("max_depth", 8), "max_nodes": args.get("max_nodes", 1000)})

func get_runtime_properties(args: Dictionary) -> Variant:
	var runtime = manager()
	if runtime == null:
		return failure("Runtime manager requires an enabled editor plugin")
	var id: Variant = args.get("session_id")
	if not id is String or id == "":
		return failure("session_id must be a nonempty string")
	if not args.get("path") is String:
		return failure("path must be a string relative to the current scene")
	var command := {"path": args.path}
	if args.has("properties"):
		if not args.properties is Array or args.properties.size() > 256:
			return failure("properties must be an array of at most 256 names")
		for name in args.properties:
			if not name is String:
				return failure("Each property name must be a string")
		command["properties"] = args.properties
	return runtime.request(id, "get_runtime_properties", command)

func get_runtime_errors(args: Dictionary) -> Dictionary:
	var runtime = manager()
	if runtime == null:
		return failure("Runtime manager requires an enabled editor plugin")
	var id: Variant = args.get("session_id")
	if not id is String or id == "":
		return failure("session_id must be a nonempty string")
	if not integer(args.get("after_sequence", 0), 0, 9007199254740991) or not integer(args.get("limit", 100), 1, 1000):
		return failure("after_sequence must be nonnegative; limit must be 1–1000")
	return runtime.errors(id, int(args.get("after_sequence", 0)), int(args.get("limit", 100)))

func register_tools(reg) -> void:
	reg.register("get_runtime_errors", "Read retained session errors and startup stderr, with monotonic pagination and explicit truncation. Does not clear logs or query editor errors.",
		{"type": "object", "properties": {"session_id": {"type": "string"}, "after_sequence": {"type": "integer", "minimum": 0, "default": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 1000, "default": 100}}, "required": ["session_id"]}, Callable(self, "get_runtime_errors"))
	reg.register("get_runtime_properties", "Read live game node properties encoded as Godot var_to_str strings. An optional name list limits getters/payload size; path is current-scene relative.",
		{"type": "object", "properties": {"session_id": {"type": "string"}, "path": {"type": "string"}, "properties": {"type": "array", "maxItems": 256, "items": {"type": "string"}}}, "required": ["session_id", "path"]}, Callable(self, "get_runtime_properties"))
	reg.register("get_runtime_tree", "Inspect the live current-scene hierarchy, including spawned nodes. Paths are relative to the running scene, not the editor. Results report truncation.",
		{"type": "object", "properties": {"session_id": {"type": "string"}, "path": {"type": "string", "default": "."}, "max_depth": {"type": "integer", "minimum": 0, "maximum": 64, "default": 8}, "max_nodes": {"type": "integer", "minimum": 1, "maximum": 10000, "default": 1000}}, "required": ["session_id"]}, Callable(self, "get_runtime_tree"))
	reg.register("resize_game_window", "Resize a standalone rendered game window and report actual window/viewport/content-scale dimensions. Does not change fullscreen mode or project stretch settings.",
		{"type": "object", "properties": {"session_id": {"type": "string"}, "width": {"type": "integer", "minimum": 64, "maximum": 8192}, "height": {"type": "integer", "minimum": 64, "maximum": 8192}}, "required": ["session_id", "width", "height"]}, Callable(self, "resize_game_window"))
	reg.register("send_input", "Inject an ordered batch of action/key/mouse_button/mouse_motion events into the game. Coordinates use original root viewport pixels. Optional wait_frames or hold_frames schedule physics-frame delays.",
		{"type": "object", "properties": {"session_id": {"type": "string"}, "events": {"type": "array", "minItems": 1, "maxItems": 256, "items": {"type": "object", "properties": {"kind": {"type": "string", "enum": ["action", "key", "mouse_button", "mouse_motion"]}, "action": {"type": "string"}, "key": {"type": "string"}, "button": {"type": "string"}, "pressed": {"type": "boolean"}, "position": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, "relative": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, "modifiers": {"type": "array", "items": {"type": "string"}}, "strength": {"type": "number", "minimum": 0, "maximum": 1}, "wait_frames": {"type": "integer", "minimum": 0, "maximum": 600}, "hold_frames": {"type": "integer", "minimum": 0, "maximum": 600}}, "required": ["kind"]}}}, "required": ["session_id", "events"]}, Callable(self, "send_input"))
	reg.register("capture_game_frame", "Capture the next rendered game viewport as PNG file or base64. Headless sessions cannot render. Coordinates refer to source viewport_size.",
		{"type": "object", "properties": {"session_id": {"type": "string"}, "downscale": {"type": "integer", "minimum": 1, "maximum": 16, "default": 1}, "format": {"type": "string", "enum": ["file", "base64"], "default": "file"}}, "required": ["session_id"]}, Callable(self, "capture_game_frame"))
	reg.register("stop_project", "Gracefully stop a specific owned game session, terminating it after a bounded grace period if necessary. Retained stopped sessions are idempotent.",
		{"type": "object", "properties": {"session_id": {"type": "string"}, "grace_seconds": {"type": "number", "minimum": 0, "maximum": 10, "default": 2}}, "required": ["session_id"]}, Callable(self, "stop_project"))
	reg.register("get_run_status", "Read current or retained game status without blocking. An omitted session_id selects the active then most recent session.",
		{"type": "object", "properties": {"session_id": {"type": "string"}}}, Callable(self, "get_run_status"))
	reg.register("run_project", "Launch saved main scene or explicit scene in a managed standalone game. Returns a starting session ID; poll get_run_status for readiness.",
		{"type": "object", "properties": {"scene": {"type": "string"}, "headless": {"type": "boolean", "default": false}, "startup_timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 120, "default": 15}}}, Callable(self, "run_project"))
