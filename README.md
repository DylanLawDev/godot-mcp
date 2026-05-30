# Godot MCP (pure-GDScript)

A [Model Context Protocol](https://modelcontextprotocol.io) server for the Godot
game engine, implemented **entirely as a Godot editor plugin** — no Node, no
external daemon, no compiled binary. The editor *is* the MCP server.

## Why

Two problems with existing Godot MCPs motivated a fresh build:

1. **No Node requirement.** Existing servers need a Node/npm runtime installed
   and version-matched. We want zero non-Godot dependencies.
2. **Multiple Claude Code instances at once.** stdio-transport servers are
   *spawned per client*, so each instance fights to own the connection to Godot.
   We want many agents driving one editor simultaneously.

## How it works

The Godot editor plugin hosts an **HTTP MCP server** (Streamable HTTP transport)
on loopback. Claude Code connects to it as a *remote* server — it never spawns a
process.

```
  Claude Code #1 ─┐
  Claude Code #2 ─┼──HTTP──▶  Godot editor plugin  ──▶  in-process tools
  Claude Code #3 ─┘          (TCPServer @127.0.0.1:8765)   (scene/script/...)
```

- **No spawning → no collisions.** Every instance points at the same URL and
  just connects. Multi-instance is structural, not bolted on.
- **No bridge.** Tools run in-process on the editor's main thread. There is no
  second protocol, no WebSocket, no glue process to maintain.
- **Truly zero extra runtime.** Ships as one addon. `git clone` into
  `addons/`, enable, done.

### Connecting Claude Code

```bash
claude mcp add --transport http godot http://127.0.0.1:8765/mcp
```

or project-scoped `.mcp.json`:

```json
{
  "mcpServers": {
    "godot": { "type": "http", "url": "http://127.0.0.1:8765/mcp" }
  }
}
```

Note: there is no `"command"` field — Claude Code only ever *connects*.

### Lifecycle & scope

- **The editor must be open** — the editor hosts the server. No headless
  per-operation spawning.
- **One editor = one server on one port** (default `8765`, overridable). Run two
  projects → two editors → two ports.
- **Loopback only, no auth in v1.** Optional bearer token is a later add.

## Why pure GDScript (not Rust/Python)

A separate daemon's only job would be translating MCP ⇄ Godot. But all Godot
work *already* lives in GDScript, and **every Godot editor API is main-thread
only** — so tool execution serializes on the editor's thread regardless of
transport language. Rust's concurrency advantage never materializes; the bridge
is pure overhead. Hosting MCP directly in the editor deletes the daemon, the
cross-process protocol, and the per-platform distribution problem in one move.

The one cost — GDScript has no built-in HTTP server — is bounded: MCP's
Streamable HTTP transport permits plain `POST → application/json` responses, so
v1 needs only HTTP/1.1 request parsing + JSON-RPC, not long-lived SSE streams.

## v1 scope (33 tools implemented)

The daily agent loop is *read code/scene → edit → run → see errors*:

- **Files/scripts:** `read_file`, `list_dir`, `search_project`, `create_script`,
  `edit_script` (whole-file overwrite *or* find/replace via `find`/`replace`/`replace_all`),
  `validate_script`, `list_scripts` (recursive `.gd` listing with `class_name`/`extends`),
  `get_open_scripts` (scripts open in the editor + the current one). Note: dedicated
  `read_script`/`search_in_files` (godot-mcp-pro parity) are intentionally covered by the
  generic `read_file`/`search_project` rather than added as separate tools.
- **Project:** `get_project_settings`, `list_project_resources`, `get_project_info`,
  plus MCP resources `godot://project/info`, `godot://scene/current`,
  `godot://script/current`
- **Scenes** *(implemented)*: `get_scene_tree`, `get_node_properties`, `create_node`
  (accepts optional `properties`), `delete_node`, `modify_node`, `duplicate_node`,
  `move_node`, `rename_node` — all operate on the currently-open scene; the mutating
  tools (`create_node`, `delete_node`, `modify_node`, `duplicate_node`, `move_node`,
  `rename_node`) are registered as editor undo/redo actions (Ctrl-Z works)
- **Signals/groups/resources** *(implemented)*: `get_signals`, `connect_signal`,
  `disconnect_signal` wire node signals to methods (persistent connections that
  serialize into the `.tscn`); `get_node_groups`, `set_node_groups`,
  `find_nodes_in_group` manage persistent group membership across the edited scene;
  `add_resource` instantiates a `Resource` subtype and assigns it to a node property;
  `set_anchor_preset` applies a `Control` layout preset; `attach_script` attaches an
  existing `.gd` to a node — all mutating tools are undoable
- **Editor** *(implemented)*: `get_output_log` and `get_editor_errors` read engine
  log/error output captured by a ring-buffer `Logger` the plugin installs via
  `OS.add_logger` (Godot exposes no public API to *read* the editor's Output dock,
  so capturing our own stream is the only robust path); `clear_output` clears **the
  MCP capture buffer, not the editor's Output dock**; `get_editor_screenshot` captures
  the editor window (PNG to a `res://` path or base64) and **requires a windowed,
  non-headless editor** — in `--headless` it returns a clean error; `reload_project`
  triggers an editor filesystem rescan. Note: `reload_plugin` (godot-mcp-pro parity) is
  intentionally **deferred** — a plugin disabling/reloading itself would tear down the
  HTTP server and `_process` loop servicing the very request, so it can't safely respond.
- **Run/feedback** *(pending)*: `run_scene`, `stop_scene`, `get_errors`,
  `get_console_log` — not yet implemented

Deferred to v2: in-game **runtime** tools (screenshot, input injection, live
node query) — they need a second live connection from the running game.
Near-full tool parity (signals, resources, project settings, input maps, asset
generation, visualizers) is also a later expansion.
