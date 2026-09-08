extends RefCounted
const Synth = preload("res://addons/godot_mcp/runtime/input_synth.gd")
const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
var bridge: Node
var _active_task
var _held: Dictionary = {}

func _init(owner: Node) -> void:
	bridge = owner

static func validate(events: Variant) -> Dictionary:
	if not events is Array or events.is_empty() or events.size() > 256:
		return {"ok": false, "error": "events must contain 1–256 input events"}
	var total_frames := 0
	for item in events:
		if not item is Dictionary:
			return {"ok": false, "error": "Each event must be an object"}
		for key in ["pressed", "echo", "double_click"]:
			if item.has(key) and not item[key] is bool:
				return {"ok": false, "error": key + " must be boolean"}
		for key in ["kind", "key", "button", "action"]:
			if item.has(key) and not item[key] is String:
				return {"ok": false, "error": key + " must be a string"}
		if item.has("strength") and (not (typeof(item.strength) in [TYPE_INT, TYPE_FLOAT]) or not is_finite(item.strength) or item.strength < 0 or item.strength > 1):
			return {"ok": false, "error": "strength must be a finite number from 0 to 1"}
		if item.has("modifiers"):
			if not item.modifiers is Array:
				return {"ok": false, "error": "modifiers must be an array"}
			for modifier in item.modifiers:
				if modifier not in ["shift", "ctrl", "alt", "meta"]:
					return {"ok": false, "error": "Unknown input modifier"}
		for key in ["position", "relative", "velocity"]:
			if item.has(key):
				if not item[key] is Array or item[key].size() != 2:
					return {"ok": false, "error": key + " must be [x,y]"}
				for component in item[key]:
					if not (typeof(component) in [TYPE_INT, TYPE_FLOAT]) or not is_finite(component):
						return {"ok": false, "error": "Coordinates must be finite numbers"}
		if item.has("wait_frames") and item.has("hold_frames"):
			return {"ok": false, "error": "wait_frames and hold_frames are mutually exclusive"}
		for key in ["wait_frames", "hold_frames"]:
			var count: Variant = item.get(key, 0)
			if not (typeof(count) in [TYPE_INT, TYPE_FLOAT]) or not is_finite(count) or count != floor(count) or count < 0 or count > 600:
				return {"ok": false, "error": key + " must be an integer from 0 to 600"}
			total_frames += int(count)
		if item.has("hold_frames") and (item.get("kind") == "mouse_motion" or not item.get("pressed", true)):
			return {"ok": false, "error": "hold_frames requires a press event"}
		if item.get("kind") == "mouse_button" and item.get("button", "").begins_with("wheel_") and item.has("hold_frames"):
			return {"ok": false, "error": "Wheel input is momentary and cannot use hold_frames"}
		var built := Synth.build(item)
		if not built.ok:
			return built
	if total_frames > 600:
		return {"ok": false, "error": "Input sequence exceeds 600 scheduled frames"}
	return {"ok": true, "frames": total_frames}

func send(args: Dictionary):
	var task := Deferred.new(30)
	var events: Variant = args.get("events")
	var checked := validate(events)
	if not checked.ok:
		task.resolve(checked)
		return task
	if _active_task != null and not _active_task.done:
		task.resolve({"ok": false, "error": "Another input sequence is running"})
		return task
	if checked.frames > 0 and bridge.get_tree().paused:
		task.resolve({"ok": false, "error": "Frame-delayed input is unavailable while paused"})
		return task
	task.deadline_msec = Time.get_ticks_msec() + int(timeout_for_frames(checked.frames, 1.0) * 1000)
	_active_task = task
	task.on_cancel = Callable(self, "release_all")
	_run(task, events.duplicate(true), checked.frames > 0)
	return task

func _run(task, events: Array, align_physics: bool) -> void:
	# Signals precede physics callbacks. Align the initial press to that boundary,
	# then N subsequent signals mean N complete game physics steps have elapsed.
	if align_physics:
		await bridge.get_tree().physics_frame
		if task.done:
			return
	var applied := 0
	for item in events:
		for _i in int(item.get("wait_frames", 0)):
			await bridge.get_tree().physics_frame
			if task.done:
				return
		if task.done:
			return
		var result := _dispatch(item)
		if not result.ok:
			release_all()
			task.resolve({"ok": false, "error": str(result.error) + " (applied_count=%d)" % applied})
			return
		applied += 1
		if item.has("hold_frames"):
			for _i in int(item.hold_frames):
				await bridge.get_tree().physics_frame
				if task.done:
					return
			var release: Dictionary = item.duplicate(true)
			release.pressed = false
			_dispatch(release)
	task.resolve({"ok": true, "value": {"session_id": bridge.session_id, "applied_count": applied, "completed_frame": Engine.get_physics_frames()}})

func _dispatch(item: Dictionary) -> Dictionary:
	# Rebuild at dispatch time: mouse masks depend on preceding presses.
	var built := Synth.build(item)
	if not built.ok:
		return built
	Input.parse_input_event(built.event)
	Input.flush_buffered_events()
	if built.event is InputEventMouseButton and Synth._mask_bit(built.event.button_index) == 0:
		return {"ok": true}
	if item.get("kind") != "mouse_motion":
		var key := ""
		if built.event is InputEventKey:
			key = "key:" + str(built.event.keycode)
		elif built.event is InputEventMouseButton:
			key = "mouse:" + str(built.event.button_index)
		elif built.event is InputEventAction:
			key = "action:" + str(built.event.action)
		if item.get("pressed", true):
			_held[key] = item.duplicate(true)
		else:
			_held.erase(key)
	return {"ok": true}

func release_all() -> void:
	for item in _held.values():
		var release: Dictionary = item.duplicate(true)
		release.pressed = false
		var built := Synth.build(release)
		if built.ok:
			Input.parse_input_event(built.event)
			Input.flush_buffered_events()
	_held.clear()

static func timeout_for_frames(frames: int, ticks_per_second: float) -> float:
	return maxf(30.0, float(clampi(frames, 0, 600)) / maxf(1.0, ticks_per_second) + 10.0)

static func timeout_for_events(events: Array, ticks_per_second: float) -> float:
	var frames := 0
	for event in events:
		if event is Dictionary:
			for key in ["wait_frames", "hold_frames"]:
				var count: Variant = event.get(key, 0)
				if typeof(count) in [TYPE_INT, TYPE_FLOAT] and is_finite(count):
					frames += int(clampf(count, 0, 600))
	return timeout_for_frames(frames, ticks_per_second)
