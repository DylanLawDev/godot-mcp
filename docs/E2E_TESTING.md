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

**tools/list** — expect all 14 tool names.
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```
Expect: `read_file`, `list_dir`, `search_project`, `create_script`, `edit_script`,
`validate_script`, `get_project_settings`, `list_project_resources`, `get_project_info`,
`get_scene_tree`, `get_node_properties`, `create_node`, `delete_node`, `modify_node`.

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

## 4. Exercise scene tools and current resources

Open `examples/scenes/main.tscn` in the editor (double-click it in the
FileSystem dock or run `godot4 --editor --path . examples/scenes/main.tscn`).
The scene must be **open in the editor** for all scene tools to work.

**get_scene_tree** — returns the node tree of the currently-open scene.
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"get_scene_tree","arguments":{}}}'
```
Expect: `isError:false`, `result.content[0].text` contains a JSON object with
a `tree` key whose `name` matches the scene's root node.

**create_node** — adds a child node (undoable).
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"create_node","arguments":{"parent_path":".","type":"Node2D","name":"Marker"}}}'
```
Expect: `isError:false`. Verify the `Marker` node appears in the Scene dock.
Press **Ctrl-Z** in the editor — the node should disappear (undo works).

**get_node_properties** — inspect a node's properties.
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"get_node_properties","arguments":{"path":"."}}}'
```
Expect: `isError:false`, response contains property names and their
`var_to_str`-encoded values for the scene root node.

**modify_node** — set a property using a `var_to_str` string (undoable).
First re-create the `Marker` node (re-run the `create_node` curl above), then:
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"modify_node","arguments":{"path":"Marker","properties":{"position":"Vector2(10, 20)"}}}}'
```
Expect: `isError:false`, response JSON includes `"set":["position"]` and
`"errors":[]`. The `Marker` node's position in the Inspector should update.

**delete_node** — removes a node (undoable).
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"delete_node","arguments":{"path":"Marker"}}}'
```
Expect: `isError:false`. The `Marker` node should be gone from the Scene dock.
Press **Ctrl-Z** — it should reappear.

**resources/read — godot://scene/current** — MCP resource for the open scene.
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":25,"method":"resources/read","params":{"uri":"godot://scene/current"}}'
```
Expect: `result.contents[0].text` contains JSON with a `path` field (the
open scene's file path, empty string for an unsaved scene) and a `tree` object
matching the live scene hierarchy. When no scene is open the body is
`{"open":false}` instead.

**resources/read — godot://script/current** — MCP resource for the open script.
First open `examples/scripts/player.gd` in the editor script tab, then:
```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":26,"method":"resources/read","params":{"uri":"godot://script/current"}}'
```
Expect: `result.contents[0].text` contains JSON with a `path` field pointing
to `player.gd` and the full script source in a `content` field. When no script
is open the body is `{"open":false}` instead.

## 5. Connect Claude Code

```bash
claude mcp add --transport http godot http://127.0.0.1:8765/mcp
claude mcp list   # "godot" should appear and be reachable
```

In a Claude Code session, confirm the 14 tools are listed and that asking Claude
to read a project file invokes `read_file`.

## Notes / known limitations (v1)

- **Loopback only, no auth.** Server binds `127.0.0.1`. A bearer token is a later add.
- **Editor must be open.** No headless per-request spawning — the editor hosts the server.
- **One editor = one port.** Two projects → two editors → two ports.
- Path handling rejects `..` traversal but does not normalize `user://` or
  percent-encoded paths (defense-in-depth, not the security boundary — loopback/trusted).
- Run/feedback and in-game runtime tools are **not yet implemented** (future plans). Scene tools (`get_scene_tree`, `get_node_properties`, `create_node`, `delete_node`, `modify_node`) are implemented and covered in section 4 above.

## Headless scenario runner

The runtime scenario runner drives a real scene headlessly (no editor). Author a
scenario JSON (target scene + ordered steps), run it, read the results JSON:

```bash
addons/godot_mcp/runtime/run_scenario.sh examples/scenarios/move_right.json /tmp/out.json
echo "exit=$?"   # 0 = every assertion passed
cat /tmp/out.json
```

`examples/scenarios/move_right.json` against `examples/scenes/runner_demo.tscn`
should report `passed: true`: it holds `ui_right` for ~1s, asserts the node moved
past x=100, and that `reached_goal` fired once.

Step types: `wait_frames`, `wait_seconds`, `input_action` (modes `press`/`release`/`tap`),
`set_property`, `create_node`, `delete_node`, `call_method`, `watch_signal`, and
`assert` (kinds `property`, `node_exists`, `node_absent`, `in_group`, `signal_count`;
ops `eq`/`ne`/`lt`/`le`/`gt`/`ge`). Input is action-based (project input map) and
poll-observable (`Input.is_action_pressed`); it does not fire `_input`/`_unhandled_input`.
