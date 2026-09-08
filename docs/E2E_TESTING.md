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

Step types: `wait_frames`, `wait_seconds`, `input_action` (modes `press`/`release`/`tap`/
`hold` — `hold` takes `frames` or `seconds` and auto-releases), `input_event`,
`set_property`, `create_node`, `delete_node`, `call_method`, `watch_signal`,
`capture_frames`, `set_paused`, `step_frames`, `capture_texture`, and `assert`
(kinds `property`, `node_exists`, `node_absent`,
`in_group`, `signal_count`; ops `eq`/`ne`/`lt`/`le`/`gt`/`ge`).

`input_action` is poll-observable (`Input.is_action_pressed`) and does not fire
`_input`/`_unhandled_input`. For that, use `input_event`, which synthesizes a raw
`InputEvent` and feeds it through `Input.parse_input_event` — the same path OS input
takes — so it updates poll state AND reaches `_input`/`_gui_input`/`_unhandled_input`,
headless included. Kinds:

- `key`: `{"kind": "key", "key": "Right", "pressed": true, "modifiers": ["ctrl"], "echo": false}`
  (`key` accepts `OS.find_keycode_from_string` names — "A", "Left", "Escape", "F1" —
  or the constant spelling "KEY_LEFT")
- `mouse_button`: `{"kind": "mouse_button", "button": "left", "position": [12, 34], "pressed": true, "double_click": false}`
  (buttons: `left`/`right`/`middle`/`wheel_up`/`wheel_down`/`wheel_left`/`wheel_right`/`xbutton1`/`xbutton2`)
- `mouse_motion`: `{"kind": "mouse_motion", "position": [40, 40], "relative": [5, 0], "velocity": [100, 0]}`
- `action`: `{"kind": "action", "action": "jump", "pressed": true, "strength": 1.0}`

Any pressed `input_event` (except `mouse_motion`) accepts `hold_frames` or
`hold_seconds` to auto-release after that duration.

`examples/scenarios/input_events.json` against `examples/scenes/input_events_demo.tscn`
exercises the whole surface — run it after runner changes and expect `passed: true`
and exit 0:

```bash
addons/godot_mcp/runtime/run_scenario.sh examples/scenarios/input_events.json /tmp/input_events.json
```

### Burst frame capture

`capture_frames` (`{"type": "capture_frames", "count": 10, "dir": "user://captures/burst",
"downscale": 2}`) pumps `count` render frames and saves each as
`<dir>/frame_0000.png`, `frame_0001.png`, ... The results JSON gains a `captures`
array with one manifest per output dir (`captured`, `errors`, and per-frame
entries with file/width/height). Repeating the step with the same `dir`
continues the same numbering.

A `--headless` process renders nothing, so every frame records a manifest error
instead of a file. Use the runner's windowed mode for real pixels (a game window
opens briefly):

```bash
addons/godot_mcp/runtime/run_scenario.sh --render examples/scenarios/burst_capture.json /tmp/burst.json
```

Expected: exit 0, `captures[0].captured == 10`, `errors == 0`, and ten numbered
PNGs in the user-data dir (`user://captures/burst` →
`~/.local/share/godot/app_userdata/<project>/captures/burst` on Linux). The same
command without `--render` still exits 0 but reports
`captured: 0, errors: 10` — capture problems are diagnosable from the manifest,
never fatal to the run.

### Frame stepping

`set_paused` (`{"type": "set_paused", "paused": true}`) flips `SceneTree.paused`
for the whole game. `step_frames` (`{"type": "step_frames", "count": 3,
"dir": "user://captures/steps", "downscale": 1}`) then advances node processing
by **exactly** `count` rendered frames — one `_process` call per step — and, if
`dir` is given, saves a PNG after each stepped frame (same manifest/numbering
rules as `capture_frames`, including the headless-records-errors behavior; a
`dir` shared between the two step types continues one numbering sequence). The
tree is left paused afterward regardless of its prior state; resume with
`set_paused: false`.

`examples/scenarios/frame_step.json` proves the exactness: it pauses, verifies
5 waited frames advance `_process` zero times, steps 3 + 1 frames and asserts
the fixture's `process_ticks` hit exactly 3 then 4, then unpauses. Run it both
ways and expect exit 0:

```bash
addons/godot_mcp/runtime/run_scenario.sh          examples/scenarios/frame_step.json /tmp/steps.json
addons/godot_mcp/runtime/run_scenario.sh --render examples/scenarios/frame_step.json /tmp/steps.json
```

The `--render` run additionally leaves the stepped frames as
`user://captures/steps/frame_0000.png` … `frame_0003.png` — frame-by-frame
diffs of consecutive stepped captures are the definitive check that a temporal
artifact (jitter, sawtooth) is gone.

### Texture readback

`capture_texture` (`{"type": "capture_texture", "path": "View", "property": "",
"out": "user://captures/subviewport.png"}`) dumps a texture reachable from a
live node to a PNG: with no `property` the node must be a SubViewport (its
render target is read); otherwise `property` is a `get_indexed` path
("texture", "material:albedo_texture") holding a `Texture2D`. A failed readback
is fatal to the run.

CPU-side textures (`ImageTexture`) work headless; GPU-backed ones (a
SubViewport's `ViewportTexture`) render nothing headless and need a windowed
run (drop `--headless`; a game window opens briefly):

```bash
# CPU texture — headless, exits 0:
addons/godot_mcp/runtime/run_scenario.sh examples/scenarios/texture_readback.json /tmp/tex.json

# SubViewport render target — headless this FAILS with a clear fatal error;
# windowed it exits 0 and writes user://captures/subviewport.png (64x48, the
# fixture's red ColorRect):
godot4 --path . --script addons/godot_mcp/runtime/scenario_runner.gd \
  -- --scenario examples/scenarios/texture_readback_subviewport.json --out /tmp/tex.json
```

The same readback is available in the editor as the `capture_texture` MCP tool
(`{path, property?, out_path?}` — PNG to a `res://` path, else base64), e.g.
against an open scene containing a SubViewport named `View`:

```bash
curl -sS -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"capture_texture","arguments":{"path":"View","out_path":"examples/scratch/view.png"}}}'

```

## Managed runtime foundation

Run `GODOT=/path/to/godot4 ./addons/godot_mcp/tests/run_runtime_integration.sh`.
It creates a temporary project, checks its autoload and paused-scene bridge,
rejects a duplicate launch, and verifies that quitting retains the child exit
status. This test does not change the open project or require a rendered window.
See [RUNTIME_BRIDGE.md](RUNTIME_BRIDGE.md) for the wire and deferred handler seams.

Call `run_project` with `scene:"res://examples/scenes/runner_demo.tscn"` and
`headless:true`; expect a starting session ID. A second launch must report the
active session rather than replacing it. Disabling the addon must stop its child.

Poll `get_run_status` for the launched ID until `running` and `bridge_connected`.
Run a missing/broken scene and confirm startup failure diagnostics; the result
must never be substituted with a newer session when an explicit old ID is used.

Use `stop_project({session_id})` on the launched run and expect `forced:false`.
Repeat it and expect `already_stopped:true`. Verify the editor and unrelated
Godot windows remain open. The integration runner now uses this public stop tool.

Run `tests/run_runtime_integration.sh --render` with GODOT set to a window-capable
binary. It opens a temporary game window and checks both file/base64 screenshots
against a red fixture pixel, then stops the game. The default headless path
checks the explicit no-renderer error instead.

The runtime fixture now injects a key press/release and mouse drag, checking
its runtime log for actual callbacks and a held left-button mask during motion.
An invalid batch must execute nothing, and delayed input while paused must fail.

The rendered integration resizes to 800×600 then 480×360 and verifies actual
window dimensions before capturing. Its headless variant rejects resizing.

Runtime-tree integration verifies a `RuntimeOnly` node spawned in `_ready`
appears through `get_runtime_tree` even though it does not exist in the scene file.

After injecting two A presses, integration reads the live fixture's `input_count`
property and verifies it is `"2"`; its scene starts at zero. This closes the
input-to-observed-state loop without looking at the edited scene.

The runtime-error fixture emits a known `push_error` and stderr message. Verify
`get_runtime_errors` includes them with source tags, file/function context where
available, and still returns them after stopping the game. Pagination is read-only.
