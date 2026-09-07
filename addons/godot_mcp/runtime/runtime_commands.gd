extends RefCounted
const Sampler = preload("res://addons/godot_mcp/runtime/performance_sampler.gd")
var sampler
const Simulation = preload("res://addons/godot_mcp/runtime/simulation_diagnostics.gd")
const NodeOps = preload("res://addons/godot_mcp/utils/node_ops.gd")
const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
const FrameCapture = preload("res://addons/godot_mcp/runtime/frame_capture.gd")
const Sessions = preload("res://addons/godot_mcp/runtime/session_manager.gd")
const InputSequence = preload("res://addons/godot_mcp/runtime/input_sequence.gd")
var simulation
var input_sequence
var _resize_task
var bridge: Node

func _init(owner: Node) -> void:
	bridge = owner
	input_sequence = InputSequence.new(owner)
	simulation = Simulation.new(owner)
	sampler = Sampler.new(owner)

func register_handlers() -> void:
	bridge.handlers["sample_performance"] = Callable(sampler, "sample")
	bridge.handlers["advance_ticks"] = Callable(simulation, "advance")
	bridge.handlers["get_simulation_snapshot"] = Callable(simulation, "snapshot")
	bridge.handlers["get_runtime_properties"] = Callable(self, "get_runtime_properties")
	bridge.handlers["get_runtime_tree"] = Callable(self, "get_runtime_tree")
	bridge.handlers["resize_game_window"] = Callable(self, "resize_game_window")
	bridge.handlers["send_input"] = Callable(input_sequence, "send")
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

func cleanup() -> void:
	input_sequence.release_all()
	simulation.cleanup()

func resize_game_window(args: Dictionary):
	var task := Deferred.new()
	if _resize_task != null and not _resize_task.done:
		task.resolve({"ok": false, "error": "Another window resize is pending"})
		return task
	if DisplayServer.get_name() == "headless":
		task.resolve({"ok": false, "error": "Cannot resize a headless game window"})
		return task
	var viewport: Window = bridge.get_tree().root
	if viewport.mode != Window.MODE_WINDOWED or viewport.is_embedded():
		task.resolve({"ok": false, "error": "Resizing requires a standalone windowed session"})
		return task
	var requested := Vector2i(int(args.get("width", 0)), int(args.get("height", 0)))
	if requested.x < 64 or requested.y < 64 or requested.x > 8192 or requested.y > 8192:
		task.resolve({"ok": false, "error": "Window dimensions must be 64–8192 pixels"})
		return task
	_resize_task = task
	viewport.size = requested
	_observe_resize(task, requested)
	return task

func _observe_resize(task, requested: Vector2i) -> void:
	await bridge.get_tree().process_frame
	await RenderingServer.frame_post_draw
	if _resize_task == task:
		_resize_task = null
	if task.done or not is_instance_valid(bridge) or not bridge.is_inside_tree():
		return
	var viewport: Window = bridge.get_tree().root
	var visible := viewport.get_visible_rect().size
	task.resolve({"ok": true, "value": {"session_id": bridge.session_id, "requested_size": [requested.x, requested.y], "window_size": [viewport.size.x, viewport.size.y], "viewport_size": [visible.x, visible.y], "content_scale_size": [viewport.content_scale_size.x, viewport.content_scale_size.y]}})

func get_runtime_tree(args: Dictionary) -> Dictionary:
	var root: Node = bridge.get_tree().current_scene
	if root == null:
		return {"ok": false, "error": "The running game has no current scene"}
	var node := NodeOps.resolve(root, args.get("path", "."))
	if node == null:
		return {"ok": false, "error": "Runtime node not found or outside current scene"}
	var value := NodeOps.serialize_tree_bounded(node, root, int(args.get("max_depth", 8)), int(args.get("max_nodes", 1000)))
	value["session_id"] = bridge.session_id
	value["frame"] = Engine.get_process_frames()
	return {"ok": true, "value": value}

func get_runtime_properties(args: Dictionary) -> Dictionary:
	var root: Node = bridge.get_tree().current_scene
	if root == null:
		return {"ok": false, "error": "The running game has no current scene"}
	var node := NodeOps.resolve(root, args.get("path", "."))
	if node == null:
		return {"ok": false, "error": "Runtime node not found or outside current scene"}
	var properties: Dictionary
	if args.has("properties"):
		var selected := NodeOps.encode_selected_props(node, args.properties)
		if not selected.ok:
			return selected
		properties = selected.value
	else:
		properties = NodeOps.encode_props(node)
	return {"ok": true, "value": {"session_id": bridge.session_id, "frame": Engine.get_process_frames(), "path": str(root.get_path_to(node)), "properties": properties}}
