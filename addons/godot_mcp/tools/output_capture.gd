@tool
extends Logger

# Ring-buffer Logger installed by the plugin. Captures engine log messages and
# errors so the MCP server can serve them via editor introspection tools. Also
# reused standalone by the headless scenario runner (runtime/scenario_runner.gd)
# to capture a run's log/errors in a non-editor process.
# Logger callbacks may fire off the main thread, so all shared state is guarded
# by a Mutex. NEVER call print/push_error inside the overrides (infinite recursion).
#
# Intentionally separate from script_tools.gd's `_CaptureLogger`: that one is a
# short-lived, single-threaded, error-only collector scoped to a single
# GDScript.reload() call (no mutex, no ring buffer). This is the long-lived,
# thread-safe, capped buffer for both logs and errors. Don't try to unify them.

var _mutex := Mutex.new()
var _entries: Array = []
var cap: int = 1000
var _sequence := 0

func _log_message(message, error) -> void:
	_mutex.lock()
	_append({"type": "log", "text": message, "error": error})
	_evict()
	_mutex.unlock()

func _log_error(_function, _file, line, code, rationale, _editor_notify, error_type, _script_backtraces) -> void:
	_mutex.lock()
	# `code` is the failed condition / error code; `rationale` is the human-readable
	# explanation passed by ERR_*_MSG macros and push_error. Keep both — the rationale
	# is the actionable part and would otherwise be dropped.
	_append({"type": "error", "function": _function, "file": _file, "line": line, "message": code, "rationale": rationale, "error_type": error_type, "backtraces": _encode_backtraces(_script_backtraces)})
	_evict()
	_mutex.unlock()

# Caller must hold the mutex.
func _evict() -> void:
	while _entries.size() > cap:
		_entries.remove_at(0)

# Returns a COPY of (filtered, last-N) entries.
func entries(limit: int = 0, errors_only: bool = false) -> Array:
	_mutex.lock()
	var out: Array = []
	for e in _entries:
		# Errors-only keeps both _log_error entries (type "error") AND stderr-flagged
		# log entries (printerr() arrives via _log_message with error == true).
		if errors_only and e.get("type") != "error" and not e.get("error", false):
			continue
		out.append(e)
	if limit > 0 and out.size() > limit:
		out = out.slice(out.size() - limit)
	var copy: Array = out.duplicate(true)
	_mutex.unlock()
	return copy

func clear() -> void:
	_mutex.lock()
	_entries.clear()
	_mutex.unlock()

# Caller holds mutex; sequence never resets when buffers are cleared.
func _append(entry: Dictionary) -> void:
	_sequence += 1
	entry["sequence"] = _sequence
	entry["timestamp_msec"] = Time.get_ticks_msec()
	_entries.append(entry)

static func _encode_backtraces(backtraces: Array) -> Array:
	var result := []
	for trace in backtraces:
		var frames := []
		for index in mini(trace.get_frame_count(), 64):
			frames.append({"function": trace.get_frame_function(index), "file": trace.get_frame_file(index), "line": trace.get_frame_line(index)})
		result.append({"language": trace.get_language_name(), "frames": frames})
	return result

func entries_since(after: int, limit: int = 100, errors_only: bool = true) -> Dictionary:
	_mutex.lock()
	var result := []
	var cursor := after
	var truncated := not _entries.is_empty() and after < int(_entries[0].sequence) - 1
	for entry in _entries:
		if entry.sequence <= after:
			continue
		cursor = entry.sequence
		if not errors_only or entry.get("type") == "error" or entry.get("error", false):
			result.append(entry.duplicate(true))
		if result.size() >= limit:
			break
	_mutex.unlock()
	return {"entries": result, "next_sequence": cursor, "truncated": truncated}
