#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
fixture_dir="$(mktemp -d '/tmp/godot build fixture.XXXXXX')"
trap 'rm -rf "$fixture_dir"' EXIT
cp -R "$repo_root/addons" "$fixture_dir/addons"
cat > "$fixture_dir/project.godot" <<'CONFIG'
config_version=5
[application]
config/name="MCP Build Fixture"
run/main_scene="res://fixture.tscn"
[editor_plugins]
enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")
CONFIG
cat > "$fixture_dir/fixture.tscn" <<'SCENE'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://fixture.gd" id="1"]
[node name="Fixture" type="Node"]
script = ExtResource("1")
SCENE
expected=completed
case "${1:-clean}" in
  clean) printf 'extends Node\nfunc _ready():\n\tpush_warning("fixture warning remains nonfatal")\n' > "$fixture_dir/fixture.gd" ;;
  colored) printf 'extends Node\nfunc _ready():\n\tprint(String.chr(27) + "[31mcolored" + String.chr(27) + "[0m")\n' > "$fixture_dir/fixture.gd" ;;
  stderr) printf 'extends Node\nfunc _ready():\n\tprinterr("fixture stderr failure")\n' > "$fixture_dir/fixture.gd"; expected=failed ;;
  runtime_error) printf 'extends Node\nfunc _ready():\n\tpush_error("fixture runtime failure")\n' > "$fixture_dir/fixture.gd"; expected=failed ;;
  parse_error) printf 'extends Node\nfunc broken(:\n' > "$fixture_dir/fixture.gd"; expected=failed ;;
  missing) printf 'extends Node\nconst Missing = preload("res://missing.gd")\n' > "$fixture_dir/fixture.gd"; expected=failed ;;
  early_exit) printf 'extends Node\nfunc _ready():\n\tget_tree().quit()\n' > "$fixture_dir/fixture.gd"; expected=failed ;;
  timeout) printf 'extends Node\n' > "$fixture_dir/fixture.gd"; expected=timed_out ;;
  *) exit 2 ;;
esac
"${GODOT:-godot4}" --headless --path "$fixture_dir" --script addons/godot_mcp/tests/integration_build.gd -- "$expected"
