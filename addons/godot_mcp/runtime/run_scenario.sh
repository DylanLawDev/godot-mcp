#!/usr/bin/env bash
# Run one scenario headless and write results JSON.
# Usage: run_scenario.sh <scenario.json> <out.json>
# Honors $GODOT (default: godot4). Exit code mirrors the run verdict
# (0 = all assertions passed).
set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GODOT="${GODOT:-godot4}"
SCENARIO="${1:?usage: run_scenario.sh <scenario.json> <out.json>}"
OUT="${2:?usage: run_scenario.sh <scenario.json> <out.json>}"
"$GODOT" --headless --path "$PROJECT_ROOT" \
	--script addons/godot_mcp/runtime/scenario_runner.gd \
	-- --scenario "$SCENARIO" --out "$OUT"
