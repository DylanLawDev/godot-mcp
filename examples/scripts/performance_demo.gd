extends Node
# Deterministic demonstration values in milliseconds, not measured game timings.
func _ready() -> void:
	Engine.time_scale = 0.0
	Performance.add_custom_monitor("demo/jobs_ms", func(): return 1.25)
	Performance.add_custom_monitor("demo/pathfinding_ms", func(): return 2.5)
	Performance.add_custom_monitor("demo/fog_ms", func(): return 0.75)
	get_tree().paused = true
func _exit_tree() -> void:
	for name in ["demo/jobs_ms", "demo/pathfinding_ms", "demo/fog_ms"]:
		Performance.remove_custom_monitor(name)
