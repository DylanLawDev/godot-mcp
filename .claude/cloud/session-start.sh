#!/usr/bin/env bash
# SessionStart hook (wired up in .claude/settings.json).
#
# In a Claude Code cloud session, start a headless Godot editor so the plugin's
# MCP server is reachable at http://127.0.0.1:8765/mcp (see .mcp.json). Does
# nothing on a local machine, where you run the real editor yourself.
#
# Needs `godot4` on PATH; .claude/cloud/setup.sh installs it. Always exits 0 so
# a failure here never blocks the session; stdout is shown to Claude as context.
set -u
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

GODOT="${GODOT:-godot4}"
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
PORT=8765 # plugin default (project setting godot_mcp/port); matches .mcp.json
LOG="${TMPDIR:-/tmp}/godot-mcp-editor.log"

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }

if port_open; then
	echo "godot-mcp: MCP server already listening on http://127.0.0.1:$PORT/mcp"
	exit 0
fi
if ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "godot-mcp: '$GODOT' not found, so the editor MCP server was not started." \
		"Set .claude/cloud/setup.sh as this environment's setup script."
	exit 0
fi

# The editor writes a .uid next to every script. The repo doesn't track them,
# so keep them out of `git status` in this throwaway clone only.
exclude="$(git -C "$ROOT" rev-parse --git-path info/exclude 2>/dev/null)"
if [ -n "$exclude" ]; then
	case "$exclude" in /*) ;; *) exclude="$ROOT/$exclude" ;; esac
	mkdir -p "$(dirname "$exclude")"
	grep -qxF '*.uid' "$exclude" 2>/dev/null || echo '*.uid' >>"$exclude"
fi

# Warm the import cache (also what the unit suite needs), then start the editor.
"$GODOT" --headless --path "$ROOT" --import >"$LOG" 2>&1 || true
setsid nohup "$GODOT" --headless --editor --path "$ROOT" >>"$LOG" 2>&1 </dev/null &

for _ in $(seq 1 90); do
	if port_open; then
		echo "godot-mcp: headless editor started; MCP server on http://127.0.0.1:$PORT/mcp (log: $LOG)"
		exit 0
	fi
	sleep 1
done
echo "godot-mcp: headless editor did not open port $PORT within 90s (log: $LOG)."
exit 0
