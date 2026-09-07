#!/usr/bin/env bash
# Real process/autoload/paused bridge regression, isolated from the source project.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
cp -R "$repo_root/addons" "$fixture_dir/addons"
cat > "$fixture_dir/project.godot" <<'EOF'
config_version=5
[application]
config/name="MCP Runtime Fixture"
[autoload]
FixtureAuto="*res://autoload.gd"
[display]
window/size/viewport_width=640
window/size/viewport_height=480
EOF
cat > "$fixture_dir/autoload.gd" <<'EOF'
extends Node
func _ready():
	print("AUTOLOAD_OK")
EOF
cat > "$fixture_dir/fixture.gd" <<'EOF'
extends Node
func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.size = Vector2i(640, 480)
	print("VIEWPORT_SIZE=", get_tree().root.get_visible_rect().size)
	get_node("Button").pressed.connect(func(): print("BUTTON_PRESSED"))
	get_tree().paused = true
	var spawned := Node.new()
	spawned.name = "RuntimeOnly"
	add_child(spawned)
	print("PAUSED_READY")
func _physics_process(_delta):
	if Input.is_key_pressed(KEY_A):
		print("POLLED_HELD_A")
func _unhandled_input(event):
	if event is InputEventKey and event.keycode == KEY_A and event.pressed:
		print("UNHANDLED_A_RECEIVED")
func _input(event):
	if event is InputEventKey and event.keycode == KEY_SPACE and event.pressed:
		get_tree().paused = false
	if event is InputEventKey and event.keycode == KEY_A and event.pressed:
		print("KEY_A_RECEIVED")
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		print("DRAG_MASK_OK")
EOF
cat > "$fixture_dir/fixture.tscn" <<'EOF'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://fixture.gd" id="1"]
[node name="Fixture" type="Node"]
script = ExtResource("1")
[node name="Red" type="ColorRect" parent="."]
offset_right = 640.0
offset_bottom = 480.0
color = Color(1, 0, 0, 1)
mouse_filter = 2
[node name="Button" type="Button" parent="."]
offset_left = 200.0
offset_top = 200.0
offset_right = 300.0
offset_bottom = 250.0
text = "Click"
EOF
"${GODOT:-godot4}" --headless --path "$fixture_dir" --script addons/godot_mcp/tests/integration_runtime.gd -- "$@"
