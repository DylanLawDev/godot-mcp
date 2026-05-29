extends CharacterBody2D

## Sample player script used as an e2e fixture for the Godot MCP tools.
## Exercised by read_file, search_project ("find_me"), and validate_script.

const SPEED := 220.0
const JUMP_VELOCITY := -400.0

var _health := 100


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	var direction := Input.get_axis("ui_left", "ui_right")
	velocity.x = direction * SPEED
	move_and_slide()


func find_me() -> String:
	# Distinctive token for search_project fixtures.
	return "find_me marker in player.gd"


func take_damage(amount: int) -> void:
	_health = max(0, _health - amount)
