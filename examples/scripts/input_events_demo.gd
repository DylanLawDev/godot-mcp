extends Node2D
# Manual-E2E fixture for raw InputEvent synthesis (input_event steps). Records
# every _input delivery into plain properties the scenario can assert on, and
# moves right while "ui_right" is held (poll path) like runner_demo.gd.

var key_events := 0
var mouse_button_events := 0
var mouse_motion_events := 0
var action_events := 0
var last_key := ""
var last_click := Vector2.ZERO
var speed := 400.0

func _input(ev: InputEvent) -> void:
	if ev is InputEventKey:
		key_events += 1
		last_key = OS.get_keycode_string((ev as InputEventKey).keycode)
	elif ev is InputEventMouseButton:
		mouse_button_events += 1
		last_click = (ev as InputEventMouseButton).position
	elif ev is InputEventMouseMotion:
		mouse_motion_events += 1
	elif ev is InputEventAction:
		action_events += 1

func _physics_process(delta: float) -> void:
	if Input.is_action_pressed("ui_right"):
		position.x += speed * delta
