# Godot MCP — End-to-End Test Instructions

These steps validate the live server (the headless unit suite is separate — run
`./addons/godot_mcp/run_tests.sh`). The MCP server only runs **while the Godot
editor is open**, because the editor *is* the server.

## Prerequisites

- Godot 4.6.x (`godot4` on PATH, or substitute your binary).
- `curl` for the raw handshake checks.
- The `godot_mcp` addon present at `addons/godot_mcp/` and enabled.
- Default port: `8765` (override with project setting `godot_mcp/port`).

## 1. Start the editor (server auto-starts when the plugin is enabled)

```bash
godot4 --editor --path .   # from this repo, or your own project's root
```

In the editor **Output** panel you should see:

```
[godot-mcp] MCP HTTP server listening on http://127.0.0.1:8765/mcp
```

If the plugin is not yet enabled: **Project → Project Settings → Plugins →
"Godot MCP" → Enable**.

## 2. Verify the MCP handshake with curl

**initialize**
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```
Expect: `result.protocolVersion = "2025-06-18"`, `result.capabilities.tools` present,
`result.serverInfo.name = "godot-mcp"`.

**tools/list** — expect all 6 tool names.
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```
Expect: `read_file`, `list_dir`, `search_project`, `create_script`, `edit_script`, `validate_script`.

## 3. Exercise each tool against the `examples/` fixtures

(The `examples/` tree ships with this repo: nested dirs, 3 `.gd` scripts with a
`find_me` token, a `.tscn` scene, and `data/notes.txt`.)

**read_file**
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"examples/scripts/player.gd"}}}'
```
Expect: `result.isError = false`, content contains `extends CharacterBody2D`.

**list_dir**
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_dir","arguments":{"path":"examples/scripts"}}}'
```
Expect: entries include `player.gd` and a directory `enemies` (`is_dir: true`).

**search_project** (recursive)
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search_project","arguments":{"query":"find_me","path":"examples"}}}'
```
Expect: hits across `player.gd`, `enemies/goblin.gd`, and `data/notes.txt` (each with `file`/`line`/`text`).

**validate_script** (valid)
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"validate_script","arguments":{"path":"examples/scripts/player.gd"}}}'
```
Expect: content `{"valid":true,"errors":[]}`.

**validate_script** (parse error → reports line + message)
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"validate_script","arguments":{"content":"extends Node\nfunc bad(\n\tpass\n"}}}'
```
Expect: `valid:false` and at least one `errors[]` entry with a `line` and `message`.

**create_script** then **edit_script** (writes under a scratch dir)
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"create_script","arguments":{"path":"examples/scratch/new_thing.gd","content":"extends Node\n"}}}'

curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"edit_script","arguments":{"path":"examples/scratch/new_thing.gd","content":"extends Node2D\n"}}}'
```
Expect: both `isError:false`; `examples/scratch/new_thing.gd` exists and ends as `extends Node2D`.
(Clean up afterward: `rm -r examples/scratch`.)

## 4. Connect Claude Code

```bash
claude mcp add --transport http godot http://127.0.0.1:8765/mcp
claude mcp list   # "godot" should appear and be reachable
```

In a Claude Code session, confirm the 6 tools are listed and that asking Claude
to read a project file invokes `read_file`.

## Notes / known limitations (v1)

- **Loopback only, no auth.** Server binds `127.0.0.1`. A bearer token is a later add.
- **Editor must be open.** No headless per-request spawning — the editor hosts the server.
- **One editor = one port.** Two projects → two editors → two ports.
- Path handling rejects `..` traversal but does not normalize `user://` or
  percent-encoded paths (defense-in-depth, not the security boundary — loopback/trusted).
- Scene, run/feedback, and runtime tools are **out of scope for v1** (future plans).
