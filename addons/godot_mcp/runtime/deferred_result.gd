@tool
extends RefCounted
# A single completion, polled by the transport. No coroutine blocks the editor.
var done := false
var value: Variant
var deadline_msec: int
var on_cancel := Callable()
var _transforms: Array[Callable] = []

func _init(timeout_seconds: float = 10.0) -> void:
	deadline_msec = Time.get_ticks_msec() + int(timeout_seconds * 1000)

func transform(callback: Callable):
	if done:
		value = callback.call(value)
	else:
		_transforms.append(callback)
	return self

func resolve(result: Variant) -> void:
	if done:
		return
	done = true
	value = result
	for callback in _transforms:
		value = callback.call(value)
	_transforms.clear()
	on_cancel = Callable()

func cancel(reason: String = "Request cancelled") -> void:
	if done:
		return
	var callback := on_cancel
	on_cancel = Callable()
	if callback.is_valid():
		callback.call()
	resolve({"ok": false, "error": reason})

func poll() -> void:
	if not done and Time.get_ticks_msec() >= deadline_msec:
		cancel("Request timed out")
