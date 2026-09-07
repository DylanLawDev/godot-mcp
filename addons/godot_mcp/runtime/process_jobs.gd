@tool
extends RefCounted
# Injectable child-process seam. A handle belongs to one job; callers never pass PIDs.
const OUTPUT_CAP := 1000
var records: Dictionary = {}
var _handles: Dictionary = {}
var _finished: Array[String] = []

func launch(id: String, executable: String, arguments: PackedStringArray, kind: String) -> Dictionary:
	var handle := OS.execute_with_pipe(executable, arguments, false)
	if handle.is_empty() or int(handle.get("pid", -1)) <= 0:
		return {"ok": false, "error": "Could not launch Godot child process"}
	_handles[id] = handle
	records[id] = {"id": id, "kind": kind, "pid": handle.pid, "state": "running", "started_at": Time.get_datetime_string_from_system(true), "ended_at": null, "exit_code": null, "output": [], "termination_reason": "", "sequence": 0}
	return {"ok": true, "value": records[id].duplicate(true)}

func poll() -> void:
	for id in _handles.keys():
		var h: Dictionary = _handles[id]
		_drain(id, h.get("stdio"), "stdout")
		_drain(id, h.get("stderr"), "stderr")
		if not OS.is_process_running(h.pid):
			_drain(id, h.get("stdio"), "stdout")
			_drain(id, h.get("stderr"), "stderr")
			var code := OS.get_process_exit_code(h.pid)
			records[id].exit_code = code if code >= 0 else null
			records[id].state = "exited" if code == 0 else "failed"
			if code < 0:
				records[id]["exit_code_unavailable"] = true
			records[id].ended_at = Time.get_datetime_string_from_system(true)
			_close(id)
			_finished.append(id)
			while _finished.size() > 20:
				records.erase(_finished.pop_front())

func _drain(id: String, pipe: FileAccess, source: String) -> void:
	if pipe == null:
		return
	# Nonblocking pipes return an empty buffer if there is no data. Bound work/frame.
	for _i in 4:
		var data := pipe.get_buffer(4096)
		if data.is_empty():
			break
		records[id].sequence += 1
		records[id].output.append({"sequence": records[id].sequence, "source": source, "text": data.get_string_from_utf8(), "timestamp_msec": Time.get_ticks_msec()})
		while records[id].output.size() > OUTPUT_CAP:
			records[id].output.pop_front()

func terminate(id: String, reason: String = "stopped") -> bool:
	if not _handles.has(id):
		return records.has(id)
	var pid: int = _handles[id].pid
	records[id].termination_reason = reason
	if not OS.is_process_running(pid):
		return true
	return OS.kill(pid) == OK

func active(id: String) -> bool:
	return _handles.has(id)

func _close(id: String) -> void:
	var h: Dictionary = _handles[id]
	for key in ["stdio", "stderr"]:
		if h.get(key) != null:
			h[key].close()
	_handles.erase(id)

func shutdown() -> void:
	for id in _handles.keys():
		terminate(id, "plugin_disabled")
		_close(id)
