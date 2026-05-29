extends Node2D

## Sample enemy in a nested directory (examples/scripts/enemies/).
## Used to verify list_dir on subdirectories and recursive search_project.

@export var damage := 5
@export var speed := 80.0


func attack() -> int:
	# find_me marker in goblin.gd
	return damage


func _ready() -> void:
	set_physics_process(true)
