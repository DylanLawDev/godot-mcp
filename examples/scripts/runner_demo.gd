extends Node2D
# Manual-E2E fixture for the headless scenario runner. Moves right while the
# built-in "ui_right" action is held and fires reached_goal once it passes x=100.

signal reached_goal

var speed := 400.0
var _fired := false

func _physics_process(delta: float) -> void:
	if Input.is_action_pressed("ui_right"):
		position.x += speed * delta
		if position.x >= 100.0 and not _fired:
			_fired = true
			emit_signal("reached_goal")
