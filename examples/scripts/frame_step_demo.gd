extends Node2D
# Manual-E2E fixture for frame stepping. Counts _process/_physics_process calls
# so a scenario can assert that pausing freezes the counters and step_frames
# advances _process by EXACTLY the stepped count.

var process_ticks := 0
var physics_ticks := 0

func _process(_delta: float) -> void:
	process_ticks += 1

func _physics_process(_delta: float) -> void:
	physics_ticks += 1
