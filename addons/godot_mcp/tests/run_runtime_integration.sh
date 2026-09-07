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
EOF
cat > "$fixture_dir/autoload.gd" <<'EOF'
extends Node
func _ready():
	print("AUTOLOAD_OK")
EOF
cat > "$fixture_dir/fixture.gd" <<'EOF'
extends Node
func _ready():
	get_tree().paused = true
	print("PAUSED_READY")
EOF
cat > "$fixture_dir/fixture.tscn" <<'EOF'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://fixture.gd" id="1"]
[node name="Fixture" type="Node"]
script = ExtResource("1")
EOF
"${GODOT:-godot4}" --headless --path "$fixture_dir" --script addons/godot_mcp/tests/integration_runtime.gd
