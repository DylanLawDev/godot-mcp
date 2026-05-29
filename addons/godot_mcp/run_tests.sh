#!/usr/bin/env bash
# Runs every addons/godot_mcp/tests/test_*.gd headless.
# Exits non-zero if any suite fails. Skips the test_case.gd base.
set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot4}"
fails=0
for t in "$PROJECT_ROOT"/addons/godot_mcp/tests/test_*.gd; do
	base="$(basename "$t")"
	[ "$base" = "test_case.gd" ] && continue
	rel="${t#"$PROJECT_ROOT"/}"
	echo ">>> $base"
	"$GODOT" --headless --path "$PROJECT_ROOT" --script "$rel" || fails=$((fails+1))
done
echo ">>> suites failed: $fails"
[ "$fails" -eq 0 ]
