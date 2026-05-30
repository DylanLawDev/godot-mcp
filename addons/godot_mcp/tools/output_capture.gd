@tool
extends Logger

# Ring-buffer Logger installed by the plugin. Captures engine log messages and
# errors so the MCP server can serve them via editor introspection tools.
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

func _log_message(message, error) -> void:
	_mutex.lock()
	_entries.append({"type": "log", "text": message, "error": error})
	_evict()
	_mutex.unlock()

func _log_error(_function, _file, line, code, _rationale, _editor_notify, error_type, _script_backtraces) -> void:
	_mutex.lock()
	_entries.append({"type": "error", "line": line, "message": code, "error_type": error_type})
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
		if errors_only and e.get("type") != "error":
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
