extends RefCounted
const Deferred = preload("res://addons/godot_mcp/runtime/deferred_result.gd")
const MAX_SAMPLE_BYTES := 4 * 1024 * 1024
const UNITS := {"frame_time_ms": "ms", "process_time_ms": "ms", "physics_time_ms": "ms", "static_memory_bytes": "bytes", "object_count": "count", "node_count": "count", "orphan_node_count": "count"}
var bridge: Node
var _active
func _init(owner: Node) -> void:
	bridge = owner

static func validate(args: Dictionary) -> String:
	var duration: Variant = args.get("duration_seconds", 2)
	var interval: Variant = args.get("interval_ms", 100)
	if typeof(duration) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(duration) or duration < 0.1 or duration > 30:
		return "duration_seconds must be a finite number from 0.1 to 30"
	if typeof(interval) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(interval) or interval != floor(interval) or interval < 16 or interval > 1000:
		return "interval_ms must be an integer from 16 to 1000"
	var names: Variant = args.get("custom_monitors", [])
	if not names is Array or names.size() > 64:
		return "custom_monitors must contain at most 64 names"
	for name in names:
		if not name is String or name.is_empty() or name.length() > 256:
			return "Custom monitor names must be nonempty strings of at most 256 characters"
	return ""

func sample(args: Dictionary):
	var error := validate(args)
	var task := Deferred.new(float(args.get("duration_seconds", 2)) + 5 if error == "" else 1)
	if error != "":
		task.resolve({"ok": false, "error": error})
	elif _active != null and not _active.done:
		task.resolve({"ok": false, "error": "A performance sample is already running"})
	else:
		_active = task
		_collect(task, args, bridge.current_request_id)
	return task

func _collect(task, args: Dictionary, request_id: String) -> void:
	var samples := []
	var budget := {"bytes": 2}
	var truncated := false
	var unavailable := []
	var units := UNITS.duplicate()
	var names := []
	for name in args.get("custom_monitors", []):
		if name not in names:
			names.append(name)
			units["custom/" + name] = "game-defined"
	var started := Time.get_ticks_msec()
	var duration := int(float(args.get("duration_seconds", 2)) * 1000)
	var interval := int(args.get("interval_ms", 100))
	var next := started
	while not task.done and Time.get_ticks_msec() - started <= duration and samples.size() < 2000:
		var now := Time.get_ticks_msec()
		if now >= next:
			var values := {"frame_time_ms": bridge.last_delta_msec, "process_time_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, "physics_time_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, "static_memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC), "object_count": Performance.get_monitor(Performance.OBJECT_COUNT), "node_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "orphan_node_count": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)}
			for name in names:
				if Performance.has_custom_monitor(name):
					var value: Variant = Performance.get_custom_monitor(name)
					if typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(value):
						values["custom/" + name] = value
					elif name not in unavailable:
						unavailable.append(name)
				elif name not in unavailable:
					unavailable.append(name)
			var sample := {"elapsed_ms": now - started, "values": values}
			if not append_bounded(samples, sample, budget):
				truncated = true
				break
			bridge._send({"kind": "progress", "request_id": request_id, "sample": sample})
			next = now + interval
		await bridge.get_tree().process_frame
	if not task.done:
		task.resolve({"ok": true, "value": {"session_id": bridge.session_id, "truncated": truncated, "sample_limit_bytes": MAX_SAMPLE_BYTES, "samples": samples, "summary": summarize(samples), "units": units, "unavailable_monitors": unavailable, "elapsed_ms": Time.get_ticks_msec() - started}})
	if _active == task:
		_active = null

static func summarize(samples: Array) -> Dictionary:
	var series := {}
	for sample in samples:
		for name in sample.values:
			if not series.has(name):
				series[name] = []
			series[name].append(float(sample.values[name]))
	var out := {}
	for name in series:
		var values: Array = series[name]
		values.sort()
		var total := 0.0
		for value in values:
			total += value
		out[name] = {"count": values.size(), "min": values[0], "max": values[-1], "mean": total / values.size(), "p95": values[int(ceil(values.size() * 0.95)) - 1]}
	return out

# Reserve ample envelope space for summaries and doubly encoded partial errors.
static func append_bounded(samples: Array, sample: Dictionary, budget: Dictionary) -> bool:
	var bytes := JSON.stringify(sample).to_utf8_buffer().size() + 1
	if int(budget.bytes) + bytes > MAX_SAMPLE_BYTES:
		return false
	budget.bytes += bytes
	samples.append(sample)
	return true
