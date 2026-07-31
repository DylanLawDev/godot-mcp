#!/usr/bin/env bash
# Run one scenario and write results JSON.
# Usage: run_scenario.sh [--render] <scenario.json> <out.json>
# --render runs windowed (a real window opens) so capture_frames steps grab
# actual pixels; the default --headless run records capture errors instead.
# Honors $GODOT (default: godot4). Exit code mirrors the run verdict
# (0 = all assertions passed).
set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GODOT="${GODOT:-godot4}"
MODE="--headless"
if [ "${1:-}" = "--render" ]; then
	MODE=""
	shift
fi
SCENARIO="${1:?usage: run_scenario.sh [--render] <scenario.json> <out.json>}"
OUT="${2:?usage: run_scenario.sh [--render] <scenario.json> <out.json>}"
# $MODE is intentionally unquoted: it expands to nothing in --render mode.
"$GODOT" $MODE --path "$PROJECT_ROOT" \
	--script addons/godot_mcp/runtime/scenario_runner.gd \
	-- --scenario "$SCENARIO" --out "$OUT"
