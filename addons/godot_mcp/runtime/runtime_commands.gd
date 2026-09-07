extends RefCounted
const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
const FrameCapture = preload("res://addons/godot_mcp/runtime/frame_capture.gd")
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
var bridge: Node

func _init(owner: Node) -> void:
	bridge = owner

func register_handlers() -> void:
	bridge.handlers["capture_game_frame"] = Callable(self, "capture_game_frame")

func capture_game_frame(args: Dictionary):
	var task := Deferred.new()
	if DisplayServer.get_name() == "headless":
		task.resolve({"ok": false, "error": "Headless display server renders no frames; launch with headless:false"})
		return task
	var downscale: Variant = args.get("downscale", 1)
	var format: Variant = args.get("format", "file")
	if not (typeof(downscale) in [TYPE_INT, TYPE_FLOAT]) or downscale != floor(downscale) or downscale < 1 or downscale > 16 or format not in ["file", "base64"]:
		task.resolve({"ok": false, "error": "Invalid capture downscale or format"})
		return task
	_capture_after_draw(task, int(downscale), format)
	return task

func _capture_after_draw(task, downscale: int, format: String) -> void:
	await RenderingServer.frame_post_draw
	if task.done or not is_instance_valid(bridge) or not bridge.is_inside_tree():
		return
	var viewport: Window = bridge.get_tree().root
	var capture := FrameCapture.new()
	var directory := Sessions.artifact_dir(bridge.session_id).path_join("capture_" + Sessions.new_id())
	var configured := capture.configure(directory, downscale)
	if not configured.ok:
		task.resolve(configured)
		return
	var frame := capture.capture(viewport)
	if frame.has("error"):
		task.resolve({"ok": false, "error": frame.error})
		return
	var value := {"session_id": bridge.session_id, "frame": Engine.get_process_frames(), "width": frame.width, "height": frame.height, "mime_type": "image/png", "viewport_size": [viewport.get_visible_rect().size.x, viewport.get_visible_rect().size.y]}
	if format == "base64":
		var bytes := FileAccess.get_file_as_bytes(frame.file)
		if bytes.size() > 12 * 1024 * 1024 - 4096:
			task.resolve({"ok": false, "error": "Frame too large for base64 response; use format:file or increase downscale"})
			return
		value["base64"] = Marshalls.raw_to_base64(bytes)
	else:
		value["file"] = frame.file
	task.resolve({"ok": true, "value": value})
