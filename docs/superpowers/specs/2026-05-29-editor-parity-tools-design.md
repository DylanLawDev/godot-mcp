# Design: godot-mcp-pro tool parity (in-editor subset)

**Date:** 2026-05-29
**Status:** Approved for implementation (user away; autonomous execution authorized)
**Base branch:** `feat/scene-tools` (PR #4, not yet merged to `main`)

## Goal

Bring our pure-GDScript editor-plugin MCP server toward feature parity with
[godot-mcp-pro](https://github.com/youichi-uda/godot-mcp-pro), implementing every
tool that is achievable **entirely in-editor on the main thread** — i.e. without a
live connection to a *running game*. godot-mcp-pro shells out to Node and runs
Godot headlessly; we run *inside* the editor, so most of its tools are actually
more natural for us, except those that inject input into / capture a running game.

## Scope decisions

These were settled during brainstorming. Decisions marked **[auto]** were made on
the user's behalf while they were away; they should be reviewed.

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **In-editor only.** Defer all running-game tools to a separate future project. | The running-game bridge (game-side autoload + second connection + lifecycle) is its own subsystem and deserves its own brainstorm. (user) |
| D2 | **Drop `execute_editor_script`.** | Arbitrary GDScript execution is an unbounded code-execution escape hatch; it doesn't fit v1's "loopback + no auth, bounded operations" threat model. Revisit with the auth story. (user) |
| D3 | **Drop running-game tools:** `get_game_screenshot`, `simulate_key`, `simulate_mouse_click`, `simulate_mouse_move`, `simulate_action`, `simulate_sequence`. | Require injecting into / capturing a live running game. No such connection exists in v1. (user, per D1) |
| D4 | **Defer `reload_plugin`. [auto]** | Self-disabling via `set_plugin_enabled("godot_mcp", false)` triggers `_exit_tree`, freeing the EditorPlugin instance that owns the HTTP server and `_process` poll loop — i.e. it kills the very loop servicing the request. Belongs with the lifecycle/auth rework. |
| D5 | **Map, don't rebuild:** `read_script`→`read_file`; `search_in_files`→`search_project`. | Already covered by existing generic tools; adding aliases is churn. Documented in README mapping table. |
| D6 | **`add_node` = enhance `create_node` with optional `properties`. [auto]** | A separate `add_node` tool would duplicate `create_node`. Adding an optional `properties` arg gives parity without redundancy. |
| D7 | **`edit_script` gains an optional find/replace mode. [auto]** | godot-mcp-pro's `edit_script` supports search/replace *or* full edit. We add an optional `{find, replace}` mode; full-overwrite (`content`) stays the default. |
| D8 | **Output/error tools read a plugin-installed ring-buffer `Logger`.** | Godot 4.6 exposes **no** public API to read or clear the editor Output dock. The only robust capture is a `Logger` subclass (`OS.add_logger`) installed by the plugin at startup, writing into a bounded ring buffer (mutex-guarded; off-main-thread calls possible). `clear_output` clears *our* buffer only — it cannot clear the real dock. |
| D9 | **`get_editor_screenshot` is windowed-only.** | The dummy display/rendering server in `--headless` returns no framebuffer. The tool returns a clear error headlessly; CI only exercises that error path. Live capture is manual-E2E only. |
| D10 | **`reload_project` = expose existing `_rescan_filesystem`** plus a script reload. | We already rescan internally after writes; surfacing it as a tool matches pro's `reload_project`. |

## Tool inventory

21 new tools + 2 enhancements (`create_node`, `edit_script`), grouped into 5 stacked PRs. Every handler keeps the
project contract: `(args: Dictionary) -> {"ok": true, "value": ...}` or
`{"ok": false, "error": String}`. Live-editor state is reached only through the
existing seam pattern (`Engine.get_meta("GodotMCPPlugin")` → `EditorInterface` /
`EditorUndoRedoManager`), so handlers degrade to a clean error headlessly and stay
unit-testable. All mutating node ops are registered as `EditorUndoRedoManager`
actions (Ctrl-Z), matching the existing scene tools.

### PR 1 — Node structure (`scene_tools.gd`)
Reuses existing `_resolve`, `_undo_redo`, `_attach`, `_make_node`, `_apply_props`.

- **`create_node` (enhance):** accept optional `properties: {name: var_str}`, applied via the existing `_apply_props`/decode path within the same undo action. (Covers pro's `add_node`.)
- **`duplicate_node`** `{path, new_name?}` — `Node.duplicate(DUPLICATE_DEFAULT)`, insert under the original's parent, **recursively set `owner` to the edited scene root** (else descendants don't serialize). Undo = detach + free.
- **`move_node`** `{path, new_parent_path, keep_global_transform?=true}` — reparent under a new parent; re-set `owner`; record old parent/index for undo.
- **`rename_node`** `{path, name}` — set `node.name` (Godot may de-duplicate); undo restores the old name. Reject empty/invalid names.

### PR 2 — Signals, groups, resources, script attach (`scene_tools.gd`)
All node-centric; all reuse `_resolve` + `_undo_redo`.

- **`get_signals`** `{path}` — `get_signal_list()` + per-signal `get_signal_connection_list()`; encode `signal`/`callable`/`flags` (4.6 shape) into `{name, args, connections:[{target_path, method, flags}]}`. Read-only.
- **`connect_signal`** `{from_path, signal, to_path, method, flags?}` — `source.connect(sig, Callable(target, method), Object.CONNECT_PERSIST)` so it serializes into the `.tscn`. Undoable; first do-op operates on a scene node so the manager picks the scene history.
- **`disconnect_signal`** `{from_path, signal, to_path, method}` — inverse; undo re-connects with `CONNECT_PERSIST`.
- **`get_node_groups`** `{path}` — `node.get_groups()` (read-only).
- **`set_node_groups`** `{path, groups:[String]}` — diff against current; `add_to_group(g, true)` (persistent) / `remove_from_group`; undoable.
- **`find_nodes_in_group`** `{group}` — walk the edited-scene-root subtree (`SceneTree.get_nodes_in_group` only sees the *running* tree), return matching node paths.
- **`add_resource`** `{path, property, type, sub_properties?}` — instantiate a `Resource` subclass via `ClassDB`, optionally set sub-properties, assign to `node.set(property, res)` (serializes as a sub-resource); undoable via `add_do_property`/`add_undo_property` capturing the old value. Validate `type` is a Resource and `property` exists.
- **`set_anchor_preset`** `{path, preset, keep_offsets?}` — Control-only; `set_anchors_preset(preset, keep_offsets)`. Accept preset by int or name (`PRESET_FULL_RECT`, etc.). Undoable (capture old anchors/offsets). Error if node is not a `Control`.
- **`attach_script`** `{path, script_path}` — validate `script_path` via `paths.gd`, `node.set_script(load(...))`; undo restores the prior script. (Pro lists this under Script Tools; it lives here because it mutates a node through the scene undo seam.)

### PR 3 — Script tools (`script_tools.gd`)
Adds a `_script_editor()` live seam (mirrors `scene_tools._current_script`).

- **`list_scripts`** `{path?}` — walk the project (or subdir) for `*.gd`, parse each for `class_name`/`extends` (lightweight text scan, no compile), return `[{path, class_name, extends}]`.
- **`get_open_scripts`** — `EditorInterface.get_script_editor().get_open_scripts()` → resource paths + which is current. Headless → empty list.
- **`edit_script` (enhance):** optional `{find, replace}` mode — read file, require `find` present (error if absent or ambiguous unless `replace_all`), write back, rescan. Full-overwrite via `content` stays default; the two modes are mutually exclusive (error if both/neither).

### PR 4 — Editor introspection (`editor_tools.gd` + `output_capture.gd` + `mcp_plugin.gd`)
Introduces shared capture infra.

- **`output_capture.gd`** — a `Logger` subclass with a mutex-guarded ring buffer (cap e.g. 1000 entries). `_log_message` → `{type:"log", text}`; `_log_error` → `{type:"error", line, message, error_type}`. Installed by `mcp_plugin._enter_tree` via `OS.add_logger`, removed in `_exit_tree`, and stashed in `Engine` meta (`GodotMCPOutputCapture`) so tools reach it. No-op/empty headlessly when the plugin isn't live.
- **`get_output_log`** `{limit?, errors_only?}` — return recent ring-buffer entries.
- **`clear_output`** — clear the ring buffer (documented: does **not** clear the editor's Output dock).
- **`get_editor_errors`** `{limit?}` — ring-buffer entries filtered to errors (`error_type == ERROR_TYPE_SCRIPT` etc.), with line/message.
- **`get_editor_screenshot`** `{path?}` — windowed: `base_control.get_viewport().get_texture().get_image().save_png_to_buffer()`, return base64 (or save to a validated `res://` path if `path` given). Headless: `{ok:false, error:"Screenshots require a windowed editor"}`.
- **`reload_project`** — `EditorInterface.get_resource_filesystem().scan()` + reload open scripts; thin wrapper over the existing rescan seam.

### PR 5 — Input map (`input_tools.gd`)
Pure `ProjectSettings` `input/*` read/write — no running game needed.

- **`get_input_actions`** — enumerate `input/*` settings → `[{name, deadzone, events:[var_str]}]`.
- **`set_input_action`** `{name, events?, deadzone?}` — create/modify an `input/<name>` action in `ProjectSettings`; `ProjectSettings.save()`. Events encoded as `var_to_str` of `InputEvent` resources (parsed via `str_to_var`). Validate action name.

## Architecture & data flow

No new layers. Each tool is a method on a `tools/*.gd` `RefCounted`, registered in
`mcp_handler._build_default_registry()` with a JSON input schema, dispatched through
the existing `tool_registry.call_tool` → `{content, isError}` adapter. The only
new infrastructure is `output_capture.gd` (PR4), wired into the plugin lifecycle.

Updated tool count after all 5 PRs: 14 → **35** registered tools (plus the 3
resources unchanged). README's "What this is" and "v1 scope" counts get updated in
each PR that adds tools.

## Error handling

- Reuse `paths.gd` `validate()` for every user-supplied file/script path (D5 tools, `attach_script`, `add_resource` save targets, screenshot `path`).
- Node ops resolve via existing `_resolve` (rejects absolute paths / `..` escapes).
- Every live-editor tool returns a specific, honest error headlessly (no scene, no
  editor, no window) — never a crash. Type mismatches (non-Control for anchors,
  non-Resource type, missing property/signal) return descriptive errors.
- `add_resource`/`connect_signal` validate the target property/signal exists before
  acting, mirroring `modify_node`'s "No such property" honesty.

## Testing

Each PR ships a `tests/test_*.gd` suite subclassing `test_case.gd`, runnable under
`run_tests.sh` headlessly. Following the existing pattern:

- **No-live-state path:** every tool asserts a clean error when no scene/editor is
  present (the dominant headless case).
- **Pure helpers tested directly** against detached node trees built in-test
  (mirrors `test_scene_tools._make_tree`): owner-recursion for `duplicate_node`,
  group diffing for `set_node_groups`, subtree walk for `find_nodes_in_group`,
  signal-connection encoding shape, find/replace logic for `edit_script`, ring
  buffer eviction for `output_capture`, preset name→int resolution.
- **Capture infra** tested by instantiating the `Logger` directly and feeding it
  synthetic `_log_message`/`_log_error` calls (no editor needed).
- `get_editor_screenshot` test asserts the headless error path only (D9).

TDD: tests are written first within each PR (red), then the handler (green).

## Stacked PR plan

Branches stack linearly; each targets the previous so reviews stay small. When
`feat/scene-tools` (#4) merges to `main`, the stack rebases onto `main`.

```
feat/scene-tools (#4, open)
  └─ feat/node-structure-tools      (PR1)
       └─ feat/node-signals-groups  (PR2)
            └─ feat/script-tools     (PR3)
                 └─ feat/editor-introspection (PR4)
                      └─ feat/input-map-tools  (PR5)
```

Each PR: tests-first (TDD) → handlers → register in `mcp_handler` → keep tool
instances alive via `reg.set_meta` → update README counts/mapping → run
`run_tests.sh` green → commit → push → open PR against its parent branch.

## Out of scope (recorded for the future running-game project)

`get_game_screenshot`, `simulate_key`, `simulate_mouse_click`, `simulate_mouse_move`,
`simulate_action`, `simulate_sequence`, `execute_editor_script`, `reload_plugin`.
