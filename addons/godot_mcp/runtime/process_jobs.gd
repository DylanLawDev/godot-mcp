@tool
extends RefCounted
# Injectable child-process seam. A handle belongs to one job; callers never pass PIDs.
const OUTPUT_CAP := 1000
var process_is_running := Callable(OS, "is_process_running")
var process_exit_code := Callable(OS, "get_process_exit_code")
var records: Dictionary = {}
var _handles: Dictionary = {}
var _finished: Array[String] = []
var _utf8_tails: Dictionary = {}
var _error_tails: Dictionary = {}

func launch(id: String, executable: String, arguments: PackedStringArray, kind: String) -> Dictionary:
	var handle := OS.execute_with_pipe(executable, arguments, false)
	if handle.is_empty() or int(handle.get("pid", -1)) <= 0:
		return {"ok": false, "error": "Could not launch Godot child process"}
	_handles[id] = handle
	records[id] = {"id": id, "kind": kind, "pid": handle.pid, "state": "running", "started_at": Time.get_datetime_string_from_system(true), "ended_at": null, "exit_code": null, "output": [], "termination_reason": "", "sequence": 0, "engine_errors": false}
	return {"ok": true, "value": records[id].duplicate(true)}

func poll() -> void:
	for id in _handles.keys():
		var h: Dictionary = _handles[id]
		# Observe exit before draining: final output may arrive during a live-to-
		# dead transition, so a pre-exit empty read must never authorize close.
		var exited: bool = not process_is_running.call(h.pid)
		var stdout_empty := _drain(id, h.get("stdio"), "stdout")
		var stderr_empty := _drain(id, h.get("stderr"), "stderr")
		# A dead child can still have buffered pipe data. Drain it over bounded
		# polls, retaining the handle until both pipes report empty.
		if exited and stdout_empty and stderr_empty:
			var code: int = process_exit_code.call(h.pid)
			records[id].exit_code = code if code >= 0 else null
			records[id].state = "exited" if code == 0 else "failed"
			if code < 0:
				records[id]["exit_code_unavailable"] = true
			records[id].ended_at = Time.get_datetime_string_from_system(true)
			_close(id)
			_finished.append(id)
			while _finished.size() > 20:
				records.erase(_finished.pop_front())

func _drain(id: String, pipe: FileAccess, source: String) -> bool:
	if pipe == null:
		return true
	for _i in 4:
		var data := pipe.get_buffer(4096)
		if data.is_empty():
			return true
		var key: String = id + ":" + str(source)
		var decoded := decode_utf8(_utf8_tails.get(key, PackedByteArray()) + data)
		_utf8_tails[key] = decoded.tail
		if decoded.text != "":
			_append_output(id, source, decoded.text)
	return false

func _append_output(id: String, source: String, text: String) -> void:
	var key := id + ":" + source
	var combined: String = _error_tails.get(key, "") + text
	if combined.begins_with("ERROR:") or combined.begins_with("SCRIPT ERROR:") or "\nERROR:" in combined or "\nSCRIPT ERROR:" in combined:
		records[id]["engine_errors"] = true
	_error_tails[key] = combined.right(64)
	records[id].sequence += 1
	records[id].output.append({"sequence": records[id].sequence, "source": source, "text": text, "timestamp_msec": Time.get_ticks_msec()})
	while records[id].output.size() > OUTPUT_CAP:
		records[id].output.pop_front()

# Preserve up to three incomplete UTF-8 bytes between arbitrary pipe reads.
static func decode_utf8(data: PackedByteArray) -> Dictionary:
	var end := data.size()
	var start := end - 1
	while start >= 0 and (data[start] & 0xc0) == 0x80 and end - start <= 4:
		start -= 1
	if start >= 0:
		var first := int(data[start])
		var expected := 1
		if (first & 0xf8) == 0xf0:
			expected = 4
		elif (first & 0xf0) == 0xe0:
			expected = 3
		elif (first & 0xe0) == 0xc0:
			expected = 2
		if end - start < expected:
			end = start
	return {"text": data.slice(0, end).get_string_from_utf8(), "tail": data.slice(end)}

func terminate(id: String, reason: String = "stopped") -> bool:
	if not _handles.has(id):
		return records.has(id)
	var pid: int = _handles[id].pid
	if not process_is_running.call(pid):
		return true
	var sent := OS.kill(pid) == OK
	if sent:
		records[id].termination_reason = reason
		records[id]["kill_sent"] = true
	return sent

func active(id: String) -> bool:
	return _handles.has(id)

func _close(id: String) -> void:
	for source in ["stdout", "stderr"]:
		var key: String = id + ":" + str(source)
		var tail: PackedByteArray = _utf8_tails.get(key, PackedByteArray())
		if not tail.is_empty():
			_append_output(id, source, tail.get_string_from_utf8())
		_utf8_tails.erase(key)
		_error_tails.erase(key)
	var h: Dictionary = _handles[id]
	for key in ["stdio", "stderr"]:
		if h.get(key) != null:
			h[key].close()
	_handles.erase(id)

func shutdown() -> void:
	for id in _handles.keys():
		terminate(id, "plugin_disabled")
		_close(id)
