#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
fixture_dir="$(mktemp -d '/tmp/godot export fixture.XXXXXX')"
trap 'rm -rf "$fixture_dir"' EXIT
cp -R "$repo_root/addons" "$fixture_dir/addons"
cat > "$fixture_dir/project.godot" <<'CONFIG'
config_version=5
[application]
config/name="MCP Export Fixture"
run/main_scene="res://fixture.tscn"
[rendering]
renderer/rendering_method="gl_compatibility"
[editor_plugins]
enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")
CONFIG
cat > "$fixture_dir/fixture.tscn" <<'SCENE'
[gd_scene format=3]
[node name="Fixture" type="Node"]
SCENE
cat > "$fixture_dir/export_presets.cfg" <<'PRESET'
[preset.0]
name="Linux Fixture"
platform="Linux"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter="addons/godot_mcp/*"
export_path="build/game.x86_64"
script_export_mode=2
[preset.0.options]
custom_template/debug=""
custom_template/release=""
binary_format/architecture="x86_64"
binary_format/embed_pck=false
PRESET
"${GODOT:-godot4}" --headless --path "$fixture_dir" --script addons/godot_mcp/tests/integration_export.gd -- "${1:-debug}"
