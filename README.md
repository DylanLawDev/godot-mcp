# Godot MCP

**Drive the Godot editor from Claude Code (or any MCP client).** Read and edit
your scripts, build and rearrange scenes, wire up signals, watch the output log,
take screenshots, and even run your game headlessly to test it — all from a
conversation with an AI agent.

Godot MCP is a [Model Context Protocol](https://modelcontextprotocol.io) server
implemented **entirely as a Godot editor plugin in pure GDScript**. There's no
Node.js, no npm, no external daemon, and no compiled binary to install. You drop
one addon into your project, enable it, and the editor itself becomes the server.

---

## Quick start

### 1. Install the plugin

Copy the `addons/godot_mcp/` folder from this repo into your Godot project's
`addons/` directory, then enable it:

> **Project → Project Settings → Plugins → Godot MCP → Enable**

That's it — no other dependencies. The moment the plugin is enabled, the editor
starts hosting an MCP server on `127.0.0.1:8765`.

> Targets **Godot 4.6.x**.

### 2. Connect your AI agent

With the Godot editor open, point Claude Code at the server:

```bash
claude mcp add --transport http godot http://127.0.0.1:8765/mcp
```

Or add it to a project-scoped `.mcp.json`:

```json
{
  "mcpServers": {
    "godot": { "type": "http", "url": "http://127.0.0.1:8765/mcp" }
  }
}
```

There is no `"command"` field — your agent only ever *connects* to the running
editor; it never launches a process.

### 3. Start building

Ask your agent things like *"add a CharacterBody2D to the current scene and
attach a movement script,"* or *"find every TODO in my scripts,"* or *"run the
game and check there are no errors in the output."* The sections below show
everything it can do.

---

## What you can do

Godot MCP exposes **56 tools** plus a set of read-only resources. Here's the full
catalogue, grouped by what you'll use them for.

### 📄 Files & scripts

Read, search, write, and validate code without leaving the conversation.

| Tool | What it does |
|------|--------------|
| `read_file` | Read any file in the project. |
| `list_dir` | List the contents of a directory. |
| `search_project` | Full-text search across the whole project. |
| `create_script` | Create a new `.gd` script. |
| `edit_script` | Overwrite a whole file, or do a targeted find/replace (`find` / `replace` / `replace_all`). |
| `validate_script` | Compile-check a script and report errors before you run anything. |
| `list_scripts` | Recursively list every `.gd` file with its `class_name` and `extends`. |
| `get_open_scripts` | See which scripts are open in the editor (and the active one). |

### 🗂️ Project

Inspect project configuration and metadata.

| Tool | What it does |
|------|--------------|
| `get_project_info` | High-level info about the project. |
| `get_project_settings` | Read entries from Project Settings. |
| `list_project_resources` | List the resources in the project. |
| `get_uid` | Look up the stable `uid://` for a resource path. |
| `update_project_uids` | Refresh the project's UID cache. |

### 🌳 Scenes

Build and rearrange the currently-open scene. **Every change here is registered
as an editor undo/redo step, so `Ctrl+Z` works exactly as you'd expect.**

| Tool | What it does |
|------|--------------|
| `get_scene_tree` | Read the node hierarchy of the open scene. |
| `get_node_properties` | Inspect a node's properties. |
| `create_node` | Add a node (optionally with starting `properties`). |
| `modify_node` | Change a node's properties. |
| `delete_node` | Remove a node. |
| `duplicate_node` | Duplicate a node. |
| `move_node` | Reparent or reorder a node. |
| `rename_node` | Rename a node. |
| `create_scene` | Create a new scene. |
| `save_scene` | Save the current scene to disk. |
| `capture_texture` | Read back a SubViewport's render target or any `Texture2D` property as a PNG (file or base64). *GPU-backed textures need a windowed editor.* |

### 🔌 Signals, groups & resources

Wire nodes together and configure them — all changes persist into the `.tscn`
and are undoable.

| Tool | What it does |
|------|--------------|
| `get_signals` | List a node's available signals. |
| `connect_signal` | Connect a signal to a method (persists into the scene file). |
| `disconnect_signal` | Remove a signal connection. |
| `get_node_groups` | List the groups a node belongs to. |
| `set_node_groups` | Set a node's group membership. |
| `find_nodes_in_group` | Find every node in a given group. |
| `add_resource` | Instantiate a `Resource` subtype and assign it to a node property. |
| `set_anchor_preset` | Apply a `Control` layout/anchor preset. |
| `attach_script` | Attach an existing `.gd` file to a node. |

### 🖥️ Editor feedback

Close the loop: see what the engine is saying.

| Tool | What it does |
|------|--------------|
| `get_output_log` | Read captured engine log output. |
| `get_editor_errors` | Read captured editor errors. |
| `clear_output` | Clear the MCP capture buffer (not the editor's Output dock). |
| `get_editor_screenshot` | Capture the editor window as a PNG file or base64. *Requires a windowed (non-headless) editor.* |
| `reload_project` | Trigger an editor filesystem rescan. |

### 🎮 Input map

Read and edit the project's input actions — works fully headlessly, no running
game needed.

| Tool | What it does |
|------|--------------|
| `get_input_actions` | Read the project's input map. |
| `set_input_action` | Add or update an input action (supports partial updates). |

### 📚 Read-only resources

In addition to tools, the server publishes live MCP resources your agent can
read directly:

- `godot://project/info` — project information
- `godot://scene/current` — the currently-open scene
- `godot://script/current` — the currently-open script

---

## Testing your game: the headless scenario runner

Beyond editing, Godot MCP ships a **headless scenario runner** that actually
*runs* your game and checks that it behaves. It launches a separate
`--headless` Godot process, loads a real scene, drives it with input-map
actions, manipulates and inspects live runtime nodes, and writes a pass/fail
results JSON.

```bash
addons/godot_mcp/runtime/run_scenario.sh examples/scenarios/move_right.json /tmp/out.json
```

A scenario is a JSON list of steps. Available step types:

- `wait_frames` / `wait_seconds` — let the game tick
- `input_action` — press/release/tap/hold an input-map action
- `input_event` — synthesize a raw key/mouse/action `InputEvent` (fires
  `_input`/`_unhandled_input` and updates poll state, with optional auto-release
  via `hold_frames`/`hold_seconds`)
- `set_property` — change a live node's property
- `create_node` / `delete_node` — manipulate the running tree
- `call_method` — call a method on a node
- `watch_signal` — record signal emissions
- `capture_frames` — save N consecutive rendered frames as numbered PNGs
  (optionally downscaled); run with `--render` to get real pixels
- `set_paused` / `step_frames` — pause the game, then advance exactly one
  rendered frame at a time (optionally capturing after each step) for
  frame-by-frame diffs of temporal artifacts
- `capture_texture` — dump a SubViewport render target or any `Texture2D`
  property of a live node to a PNG
- `assert` — check a condition and pass/fail the run

This runs separately from the editor (it's launched via the shell, not over
MCP), so you can use it in CI. Because a headless process renders nothing,
`capture_frames` needs the windowed mode:

```bash
addons/godot_mcp/runtime/run_scenario.sh --render examples/scenarios/burst_capture.json /tmp/out.json
```

The results JSON gains a `captures` manifest (one entry per output dir) listing
every written frame file and its dimensions — ten consecutive frames make
temporal artifacts like jitter or sawtooth edges obvious where a single
screenshot can't.

---

## Why it's built this way

Most Godot MCP servers require a Node.js runtime and run as a separate process
that bridges your AI client to the editor. Godot MCP deliberately avoids both:

- **Zero non-Godot dependencies.** No Node, no npm, no compiled binary, no
  per-platform distribution problem. Ship one addon, `git clone`, enable, done.
- **Many agents, one editor.** Traditional stdio MCP servers are *spawned per
  client*, so each AI instance fights to own the connection. Godot MCP hosts a
  single HTTP server that every instance simply connects to — so multiple Claude
  Code sessions can drive the same editor at once.

```
  Claude Code #1 ─┐
  Claude Code #2 ─┼──HTTP──▶  Godot editor plugin  ──▶  in-process tools
  Claude Code #3 ─┘          (TCPServer @127.0.0.1:8765)   (scene/script/...)
```

**Why pure GDScript instead of Rust or Python?** Every Godot editor API is
main-thread only, so tool execution serializes on the editor's thread no matter
what language the bridge is written in. A separate daemon's only job would be
translating MCP ⇄ Godot — pure overhead. Hosting MCP directly inside the editor
deletes the daemon, the cross-process protocol, and the distribution headache in
one move. The one cost (GDScript has no built-in HTTP server) is small: MCP's
Streamable HTTP transport allows plain `POST → application/json` responses, so
the plugin only needs basic HTTP/1.1 parsing and JSON-RPC.

---

## Things to know

- **The editor must be open.** The editor *is* the server — there's no headless
  per-operation spawning for the MCP tools (the scenario runner is the
  exception, and it spawns its own process on purpose).
- **One editor = one server on one port** (default `8765`, override via the
  `godot_mcp/port` project setting). Two projects open → two editors → two
  ports.
- **Loopback only, no auth in v1.** The server binds to `127.0.0.1`. An optional
  bearer token is planned. Don't expose the port to untrusted networks.
- **Managed runtime:** launch a game session with `run_project`, then use its
  session ID for screenshots, input, window resizing and live node queries.
  These use a separate authenticated game connection; headless games do not render.

---

## Contributing & development

Working on the plugin itself? See [`CLAUDE.md`](CLAUDE.md) for the architecture,
request flow, and conventions, and [`docs/E2E_TESTING.md`](docs/E2E_TESTING.md)
for live-server testing. The headless unit suite runs with:

```bash
./addons/godot_mcp/run_tests.sh
```

## License

See [`LICENSE`](LICENSE).

Runtime infrastructure is documented in [RUNTIME_BRIDGE.md](docs/RUNTIME_BRIDGE.md).
The foundation provides isolated managed sessions and nonblocking communication;
public runtime tools are added by the follow-up implementation issues.

### Managed game launch

`run_project({scene?, headless=false, startup_timeout_seconds=15})` launches saved
project content in a standalone child. Omit scene to use the configured main
scene; `res://`, project-relative and registered `uid://` scenes are supported.
For example, `{"scene":"res://examples/scenes/runner_demo.tscn","headless":true}`
returns a `session_id` and `state:"starting"`. A second active run is rejected.
Readiness and startup failures are recorded asynchronously; this does not save
unsaved editor changes. Headless runs cannot capture rendered frames.

`get_run_status({session_id?})` reads readiness, PID, scene, bridge connectivity,
capabilities, timestamps, nullable exit code and diagnostic output. Omit the ID
for the active or most recent run; with no runs it returns `state:"idle"`.
For example, `{"session_id":"<run_project result>"}` selects that exact run even
after exit. A disconnected bridge does not by itself mean the game crashed.

`stop_project({session_id, grace_seconds=2})` stops that owned game and returns
`state`, `already_stopped`, `forced` and nullable `exit_code`. It first requests
normal quit, then terminates the owned child if the grace period expires.
An explicit ID prevents an old caller stopping a newer game. The response is
deferred while other MCP clients stay responsive. Repeating a completed stop is safe.

`capture_game_frame({session_id, downscale=1, format="file"})` captures the next
rendered root viewport into a unique PNG artifact. The result includes width,
height, original viewport_size, frame and absolute file path; `format:"base64"`
returns PNG data instead. For example, `{"session_id":"<id>","downscale":2}`
returns half-resolution pixels. Headless runs fail clearly; this captures the
game rather than the editor window. Map downscaled image positions back to the
reported original viewport_size when sending input.

`send_input({session_id, events:[...]})` injects ordered key, action, mouse_button
and mouse_motion events using the existing scenario event format. Example drag:
`[{"kind":"mouse_button","button":"left","position":[20,20]},
{"kind":"mouse_motion","position":[100,100],"relative":[80,80]},
{"kind":"mouse_button","button":"left","pressed":false,"position":[100,100]}]`.
Use wait_frames before an event or hold_frames to auto-release a press afterward.
A batch is validated before dispatch and concurrent sequences are rejected.
Explicit presses remain held until release; stop/disconnect cancels injected holds.
Timed input is unavailable while paused. Applied event count excludes synthesized
hold releases. Coordinates are original viewport pixels, before capture downscaling.

`resize_game_window({session_id,width,height})` requests a standalone game window
size (64–8192 pixels per axis) and returns actual window_size, viewport_size and
content_scale_size after a rendered frame. For example, `{"session_id":"<id>",
"width":800,"height":600}`. OS constraints may clamp the request. Headless,
fullscreen and embedded modes are rejected; project stretch settings are preserved.

`get_runtime_tree({session_id,path=".",max_depth=8,max_nodes=1000})` inspects the
live scene, including runtime-spawned children. It returns tree, frame and an
explicit truncated flag. A node includes name/type/path/script/children; paths
are relative to the current game scene. Example: `{"session_id":"<id>",
"max_depth":2}`. This does not use the edited scene or expose bridge internals.

`get_runtime_properties({session_id,path,properties?})` reads the running node's
values using the editor tool's `var_to_str` encoding. Example: `{"session_id":
"<id>","path":"Settler","properties":["position","name"]}`. Omit the filter
for all inspectable properties, or pass `[]` for none. Unknown names fail before
getters run. Values reflect live state, not saved scene defaults; oversized
responses should be narrowed with the property filter.

`get_runtime_errors({session_id,after_sequence=0,limit=100})` returns session-scoped
errors with next_sequence and truncated flags. Structured entries include function,
file, line and available stack frames. Startup/exit stderr is retained separately
with source and possible_duplicate tags because it can also represent a structured
logger error. Example pagination: pass the previous next_sequence as after_sequence.
Reads do not clear logs, and completed sessions remain queryable. A source gap
reports truncated even when the retained editor-side ring itself has not filled.

`run_scenario({scenario_path,render=false,timeout_seconds=60})` exposes the existing
scenario runner as a background job. Example: `{"scenario_path":
"examples/scenarios/move_right.json"}` returns scenario_id, state and result_path.
Capture paths are remapped into that run's managed directory using an execution
copy; the source JSON is unchanged. One background scenario/build job may run at
a time, independently of the interactive session. Poll with get_scenario_result.

`get_scenario_result({scenario_id})` returns running/completed/failed/timed_out
state, exit code, diagnostics, the existing runner result (assertions, logs and
capture manifests), and PNG artifact metadata. Completed assertion failures have
passed:false; missing/malformed results and incompatible exit codes are failures.
Large inline results are replaced with a result_path reference. Reads are cached
after completion and do not parse files while the runner is writing them.

`get_simulation_snapshot({session_id,sections?,entity_ids?})` reads an instrumented
game's jobs, reservations, inventories, paths, power and needs at one authoritative
tick. Example: `{"session_id":"<id>","sections":["jobs","inventories"],
"entity_ids":["settler-1"]}`. Games must implement the optional
[simulation adapter](docs/SIMULATION_ADAPTER.md); unavailable instrumentation is
reported clearly. The included simulation_demo scene is a deterministic fixture,
not an integration with an external settlement game.

`advance_ticks({session_id,ticks})` advances 1–10000 authoritative simulation ticks
through the adapter. It returns tick_before, tick_after, advanced_ticks and
paused:true. The scheduler stays controlled for inspection; start a new session
to resume ordinary play in this initial API. Commands have a 30-second game-side
budget, yield between bounded work slices, and report completed ticks on failure.
There is no rollback and no substitution of rendered/physics frames for game ticks.

`sample_performance({session_id,duration_seconds:2,interval_ms:100,
custom_monitors:["demo/jobs_ms"]})` returns timestamped samples, per-metric
count/min/max/mean/p95, units, and unavailable monitor names. Frame delta is
sampled CPU frame duration, not GPU timing. Sampling follows actual process frames
(including paused games); slow frames can reduce sample count and overshoot the
requested duration. Missing custom timings are never inferred. The performance
fixture registers deterministic demonstration values in milliseconds; real games
must register their own measured `Performance` custom monitors. Interrupted calls
return an error containing JSON with `partial:true` and received samples.

`validate_project({scene:"res://main.tscn",startup_seconds:3,timeout_seconds:120})`
returns a job ID immediately. Poll `validate_project({job_id:"…"})` for snapshot,
import and startup stages, pass/fail, diagnostics and retained log/report artifacts.
It checks saved-file imports and startup only. A temporary project copy preserves
autoloads and disables this MCP editor plugin; other editor plugins still run.
Copies exclude `.git`, `.godot`, common build directories, configured export files
and managed artifacts. Symbolic links are rejected with an explicit error. Normal
completion removes the copy; disabling the plugin mid-job can retain an unfinished
copy in the job artifact directory. One scenario/validation/export job runs at a time.

Performance sample data is capped at 4 MiB; oversized requests finish early with
`truncated:true`, preserving collected samples instead of failing the bridge limit.

`export_build({preset:"Linux",mode:"release",timeout_seconds:600})` starts an
isolated export; poll `export_build({job_id:"…"})` for stages, exit status,
preset/mode/version and an absolute-path artifact manifest with byte sizes.
The preset must already exist and target Linux, Windows Desktop or macOS, with
matching installed/custom templates. Outputs use a fresh managed directory and
are verified nonempty before success. Signing/export prerequisites remain the
host's responsibility. Saved export credentials are copied into the temporary
cache when present, redacted from retained build logs, and removed with the copy.
Exports are never executed or published, and the runtime bridge is not activated.
Frame-delayed input aligns to a physics boundary so a one-frame hold is visible
to one complete physics step. Both sides reserve a conservative deadline using
Godot's minimum tick rate, including games that change the rate at runtime.
