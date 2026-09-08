extends SceneTree
const Sequence = preload("res://addons/godot_mcp/runtime/input_sequence.gd")
class Counter extends Node:
	var session_id := "test"
	var held_steps := 0
	func _physics_process(_delta: float) -> void:
		if Input.is_key_pressed(KEY_A):
			held_steps += 1
var failures := []
func _initialize() -> void:
	_main.call_deferred()
func _main() -> void:
	var counter := Counter.new()
	root.add_child(counter)
	var sequence := Sequence.new(counter)
	Engine.physics_ticks_per_second = 30
	for count in [1, 2, 3]:
		counter.held_steps = 0
		var task = sequence.send({"events": [{"kind": "key", "key": "A", "pressed": true, "hold_frames": count}]})
		while not task.done:
			task.poll()
			await process_frame
		if not task.value.ok or counter.held_steps != count:
			failures.append({"requested": count, "observed": counter.held_steps, "result": task.value})
	sequence.release_all()
	counter.queue_free()
	print("INPUT HOLD INTEGRATION: ", failures)
	quit(0 if failures.is_empty() else 1)
