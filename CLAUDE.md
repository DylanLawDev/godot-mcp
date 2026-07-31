# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A [Model Context Protocol](https://modelcontextprotocol.io) server for Godot, implemented **entirely as a Godot editor plugin in pure GDScript** — no Node, no external daemon, no compiled binary. The editor *is* the MCP server. It hosts an HTTP server on loopback (default `127.0.0.1:8765/mcp`) using MCP's Streamable HTTP transport; Claude Code connects as a *remote* server and never spawns a process. This is what enables many Claude Code instances to drive one editor at once (stdio servers are spawned per-client and would collide).

All code lives under `addons/godot_mcp/`. Every Godot editor API is main-thread only, so tool execution is inherently serialized — the architecture leans into this rather than fighting it with threads.

## Commands

```bash
# Run the full headless unit suite (CI runs exactly this). Honors $GODOT (default: godot4).
./addons/godot_mcp/run_tests.sh

# Run a single suite directly:
godot4 --headless --path . --script addons/godot_mcp/tests/test_script_tools.gd

# Run a headless scenario (runtime testing, separate from the unit suite):
addons/godot_mcp/runtime/run_scenario.sh examples/scenarios/move_right.json /tmp/out.json

# Start the editor (auto-starts the MCP server when the plugin is enabled):
godot4 --editor --path .

# Connect Claude Code to a running editor:
claude mcp add --transport http godot http://127.0.0.1:8765/mcp
```

Targets Godot **4.6.x** (CI pins `4.6.1`). E2E (live-server) testing is manual — see `docs/E2E_TESTING.md`.

## Request flow

A request traverses these layers, each a small `RefCounted` with a single seam:

```
TCP bytes → http_server.gd → http_message.gd (parse) → mcp_handler.handle_message(text)
          → jsonrpc.gd (parse/build) → tool_registry.call_tool(name, args) → tools/*.gd
```

- **`mcp_plugin.gd`** — `EditorPlugin` entry point. On `_enter_tree` it registers itself in `Engine` metadata under `"GodotMCPPlugin"`, builds the handler + server, and polls the server every frame via `_process`. Port comes from project setting `godot_mcp/port` (default `8765`).
- **`http_server.gd`** — raw `TCPServer` loop. Accumulates bytes per client until headers + full `Content-Length` body arrive, then dispatches. Only `POST /mcp*` is served. **Connection: close per request** (no keep-alive, no SSE) — a v1 simplification the README justifies.
- **`mcp_handler.gd`** — `handle_message(text) -> String` is the **single dispatch seam used by both the HTTP server and every handler test**. Returns `""` for notifications (server replies HTTP 202, no body). Handles `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`.
- **`tool_registry.gd`** — holds `{name, description, inputSchema, handler: Callable}` entries. `call_tool` adapts the internal result contract to the MCP `tools/call` shape.
- **`tools/*.gd`** — actual tool logic. All 39 tools are wired up in `mcp_handler._build_default_registry()`.

## Conventions that matter

- **Tool result contract:** every tool handler takes `(args: Dictionary)` and returns `{"ok": bool, "value": ...}` on success or `{"ok": false, "error": String}` on failure. `tool_registry` translates this into MCP `{content: [{type:"text", text}], isError}`. Non-string `value`s are `JSON.stringify`'d. Keep this shape when adding tools.
- **Registering a new tool:** add the handler method to a `tools/*.gd` file, then `reg.register(name, description, inputSchema, Callable(instance, "method"))` in `_build_default_registry()`. Stash the tool instance via `reg.set_meta(...)` so it isn't garbage-collected (see the `_files`/`_scripts` metas).
- **Resources:** MCP resources are served by `resource_registry.gd` (mirror of `tool_registry.gd`); register them in `mcp_handler._build_default_resource_registry()`. Resource handlers use the same `{ok, value/error}` contract as tools; the registry adapts the result into `{contents: [{uri, mimeType, text}]}`.
- **Path safety:** all file/script tools must run user paths through `utils/paths.gd` `validate()`, which normalizes to `res://` and rejects `..` traversal. This is defense-in-depth, not the security boundary (the boundary is loopback + no auth in v1).
- **`@tool` everywhere:** all addon scripts are `@tool` because they run inside the editor.
- **Filesystem rescan:** after writing files, tools call `_rescan_filesystem()`, which is a no-op unless the live editor plugin is present in `Engine` metadata — this is what keeps tools testable headlessly.
- **`validate_script` gotcha:** it strips top-level `class_name` declarations before its detached `GDScript.reload()` compile, otherwise validating an on-disk file that declares a `class_name` falsely fails with "Class X hides a global script class" (the class is already globally registered from disk). Preserve this behavior.

## Testing conventions

Tests subclass `tests/test_case.gd` (a `SceneTree` with `assert_*` helpers); any method named `test_*` auto-runs in `_init`, and the process exits non-zero if any assertion fails. `run_tests.sh` runs every `test_*.gd` and skips the `test_case.gd` base. Test against the `handle_message` / tool-result seams rather than the HTTP/TCP layer where possible. `examples/` ships fixtures (nested dirs, scripts with a `find_me` token, a scene, `data/notes.txt`) used by the manual E2E flow.

## Scope

v1 is the lean editor core (39 tools: `read_file`, `list_dir`, `search_project`, `create_script`, `edit_script`, `list_scripts`, `get_open_scripts`, `validate_script`, `get_project_settings`, `list_project_resources`, `get_project_info`, `get_scene_tree`, `get_node_properties`, `create_node`, `delete_node`, `modify_node`, `duplicate_node`, `move_node`, `rename_node`, `get_signals`, `connect_signal`, `disconnect_signal`, `get_node_groups`, `set_node_groups`, `find_nodes_in_group`, `add_resource`, `set_anchor_preset`, `attach_script`, `create_scene`, `save_scene`, `get_output_log`, `clear_output`, `get_editor_errors`, `get_editor_screenshot`, `reload_project`, `get_input_actions`, `set_input_action`, `get_uid`, `update_project_uids`), plus the MCP resource layer serving `godot://project/info`, `godot://scene/current`, and `godot://script/current`. Run/feedback tools and in-game runtime tools (screenshot, input injection) remain out of scope for v1 — see the README and `docs/superpowers/plans/`.

Beyond the in-editor MCP tools, a **headless scenario runner** (`addons/godot_mcp/runtime/`)
lets Claude launch a separate `--headless` Godot process that runs a real scene, drives it
with input-map actions, and manipulates/inspects live runtime nodes, emitting a pass/fail
results JSON. It is launched via Bash (`runtime/run_scenario.sh`), not over MCP, and shares
node-manipulation logic with the editor tools through `utils/node_ops.gd`. Input can be
action-based (`input_action`, poll-observable, with press/release/tap/hold modes) or raw
`InputEvent` synthesis (`input_event` via `runtime/input_synth.gd`, which also fires
`_input`/`_unhandled_input`); in-game screenshots are deferred (v2).
