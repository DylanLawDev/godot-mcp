extends SceneTree
const LogSanitizer = preload("res://addons/godot_mcp/runtime/log_sanitizer.gd")
const Capture = preload("res://addons/godot_mcp/tools/output_capture.gd")
class ValidationLogger extends Capture:
	var failures := 0
	func _log_message(message, error) -> void:
		super._log_message(message, error)
		if error:
			_mutex.lock()
			failures += 1
			_mutex.unlock()
	func _log_error(function, file, line, code, rationale, notify, error_type, backtraces) -> void:
		super._log_error(function, file, line, code, rationale, notify, error_type, backtraces)
		_mutex.lock()
		if error_type != Logger.ERROR_TYPE_WARNING:
			failures += 1
		_mutex.unlock()
var logger
var _out := ""
var _deadline := 0
var _started := false
func _initialize() -> void:
	logger = ValidationLogger.new()
	OS.add_logger(logger)
	var args := {}
	var argv := OS.get_cmdline_user_args()
	for i in range(0, argv.size() - 1, 2):
		args[argv[i]] = argv[i + 1]
	_out = args.get("--out", "")
	_start.call_deferred(args)
func _start(args: Dictionary) -> void:
	var scene: Variant = load(args.get("--scene", ""))
	if not scene is PackedScene:
		push_error("Validation scene could not load")
		_finish(false)
		return
	var instance: Node = scene.instantiate()
	root.add_child(instance)
	current_scene = instance
	_deadline = Time.get_ticks_msec() + int(float(args.get("--seconds", "3")) * 1000)
	_started = true
func _process(_delta: float) -> bool:
	if _started and Time.get_ticks_msec() >= _deadline:
		_finish(true)
	return false
func _finish(completed: bool) -> void:
	_started = false
	# Include scene/autoload shutdown callbacks in the validation verdict.
	current_scene = null
	for child in root.get_children():
		if is_instance_valid(child) and child.get_parent() == root:
			child.free()
	await process_frame
	var passed: bool = completed and logger.failures == 0
	var file := FileAccess.open(_out, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify({"completed": completed, "passed": passed, "error_count": logger.failures, "diagnostics": LogSanitizer.clean_value(logger.entries())}))
	file.close()
	quit(0 if passed else 1)
