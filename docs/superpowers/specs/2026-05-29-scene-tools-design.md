# Scene Tools & "current" Resources — Design Spec

**Date:** 2026-05-29
**Status:** Approved (brainstorming complete)
**Sub-project:** 2 of 4 in the "feature-parity" roadmap (follows `2026-05-29-project-and-resources-design.md`).

## Goal

Add live scene-tree introspection and node CRUD to the Godot MCP server, plus the two
"current" MCP resources that expose what the human is actively looking at in the editor:

- Tools: `get_scene_tree`, `get_node_properties`, `create_node`, `delete_node`, `modify_node`
- Resources: `godot://scene/current`, `godot://script/current`

This is the sub-project containing the **live-editor-vs-headless architectural fork**: unlike
the file/project tools, these operate on editor state (`EditorInterface.get_edited_scene_root()`,
the open script) that does not exist in a headless test run. The design splits *editor-state
acquisition* (thin, live-only, no-ops headlessly) from *node logic* (pure, fully unit-tested by
constructing real `Node` trees), mirroring the existing `_rescan_filesystem()` seam.

## Decisions (from brainstorming)

1. **Mutations go through `EditorUndoRedoManager`.** `create_node`/`delete_node`/`modify_node`
   register do/undo actions so the human can Ctrl-Z any AI change and edits show up as normal
   editor history. The do/undo callables are the same pure mutation primitives the tests call
   directly.
2. **Property values cross JSON via `var_to_str`/`str_to_var`.** Read encodes each value with
   `var_to_str` (e.g. `"Vector2(1, 2)"`); write decodes with `str_to_var`. Full round-trip
   fidelity for built-in types, transported as JSON strings.
3. **`get_node_properties` returns the full `get_property_list()`** (with `PROPERTY_USAGE_CATEGORY`
   / `GROUP` / `SUBGROUP` separator entries filtered out, since they are not real properties).

## Architecture

### New file: `tools/scene_tools.gd`

`@tool extends RefCounted`. Follows the standard tool result contract: every public handler takes
`(args: Dictionary)` and returns `{"ok": true, "value": ...}` or `{"ok": false, "error": String}`.

**Node addressing.** Nodes are addressed by a `NodePath` *relative to the scene root*. The root
itself is `"."`. A child is `"Player/Sprite2D"`. `_resolve(root, path)` returns the `Node` or `null`.

**Live seams (thin, editor-only).**

- `_edited_scene_root() -> Node`: returns `EditorInterface.get_edited_scene_root()` when the plugin
  is live (`Engine.has_meta("GodotMCPPlugin")`), else `null`. Headlessly → `null`.
- `_undo_redo()`: returns the plugin's `EditorUndoRedoManager` when live, else `null`.

When `_edited_scene_root()` is `null`, every tool returns `{"ok": false, "error": "No scene is currently open"}`.

**Pure helpers (fully unit-tested by building `Node` trees in the test):**

- `_serialize_tree(node, root) -> Dictionary`: `{name, type, path, script, children:[...]}`.
  `type` is `node.get_class()`. `script` is the attached script's `resource_path` or `null`.
  `path` is the node's path relative to `root` (`"."` for the root).
- `_resolve(root, path) -> Node`: maps a relative NodePath string to a `Node` (or `null`).
- `_encode_props(node) -> Dictionary`: iterates `node.get_property_list()`, skips entries whose
  `usage` is a category/group separator, and maps `name -> var_to_str(node.get(name))`.
- Mutation primitives (the do/undo callables): `_attach(parent, child, root)` (adds child and sets
  `owner = root` so it persists on save), `_detach(parent, child)`, `_apply_props(node, decoded)`.

### Tool behaviors

| Tool | Args | Success value | Notes |
|---|---|---|---|
| `get_scene_tree` | `{}` | `{tree: {...}}` | Serialized from the edited scene root. |
| `get_node_properties` | `{path}` | `{path, type, properties}` | `path` not found → error. |
| `create_node` | `{parent_path, type, name?}` | `{path}` | `type` must be a valid, instantiable `Node` class (`ClassDB.can_instantiate` and is a `Node`), else error. `name` defaults to the class name; the actual assigned name (after Godot de-duplication) is returned in `path`. New node `owner` set to scene root. |
| `delete_node` | `{path}` | `{deleted: path}` | Refuses to delete the scene root (`"."`) → error. |
| `modify_node` | `{path, properties}` | `{path, set:[names], errors:[{name, error}]}` | Each value `str_to_var`-decoded then `node.set(name, value)`. A property that doesn't exist or fails to decode is reported in `errors`; successfully applied names in `set`. |

**Mutation flow (live editor).** For each mutating tool: resolve the target/parent (error if
missing), get `_undo_redo()`, then `create_action(label)`, `add_do_method(...)`,
`add_undo_method(...)`, `commit_action()` — `commit_action` runs the do-method immediately. For
`modify_node`, old values are captured before the action so undo restores them.

### New file change: `mcp_plugin.gd`

Expose the editor undo/redo manager so the live seam can reach it via the registered plugin
metadata. The plugin already registers itself under `Engine` meta `"GodotMCPPlugin"`; `_undo_redo()`
calls `get_undo_redo()` on it.

### Resources: `resource_registry`

Two new resources registered in `mcp_handler._build_default_resource_registry()`, reusing the shared
`SceneTools` instance. Handlers use the `{ok, value}` contract; the registry serializes `value`.

- `godot://scene/current` (`application/json`): `{path, tree}` where `path` is
  `root.scene_file_path` and `tree` reuses `_serialize_tree`. When no scene is open → `{open: false}`.
- `godot://script/current` (`application/json`): `{path, content}` from
  `EditorInterface.get_script_editor().get_current_script()` (path = `resource_path`, content =
  `source_code`). When no script is open → `{open: false}`.

Both resources return `ok: true` with `{open: false}` (not an error) when nothing is open, so a read
always succeeds with a well-formed body.

### Wiring: `mcp_handler.gd`

- Construct one `SceneTools` instance in `_init`, pass it to both builders (same pattern as the
  shared `ProjectTools`).
- `_build_default_registry`: register the 5 tools with inputSchemas; `set_meta("_scene", scene)`.
- `_build_default_resource_registry`: register the 2 resources; reuse the same `_scene` instance.

## Testing

New `tests/test_scene_tools.gd` (subclass of `test_case.gd`). All node logic is tested headlessly by
building `Node` trees in-process — no live editor required:

- **Serialize:** build a small tree (root + named children + a child with a script), assert
  `_serialize_tree` shape, `type`, relative `path` values, and `script` path/null.
- **Resolve:** `"."` → root; nested path → correct node; bad path → `null`.
- **Property encode:** a node with a `Vector2`/`Color`/int property round-trips through
  `var_to_str`; category/group separators are excluded.
- **Property decode + apply:** `_apply_props` with `str_to_var`-encoded values sets primitives and a
  `Vector2`; an unknown property name is reported in `errors`, not applied.
- **Mutation primitives:** `_attach` adds a child and sets `owner`; `_detach` removes it;
  delete-root is refused.
- **Guard paths:** with no live editor, each public tool returns the "No scene is currently open"
  error.

Handler/registry wiring is tested in `test_mcp_handler.gd` via the `handle_message` seam: `tools/list`
includes the 5 new tools; `resources/list` includes the 2 new resources; `resources/read` on
`godot://scene/current` and `godot://script/current` returns a well-formed `{open: false}` body
headlessly.

E2E (live editor: actual create/delete/modify with undo, and the populated "current" resources) is
manual — added to `docs/E2E_TESTING.md`.

## Scope (YAGNI)

- Operates only on the **current edited scene** — no scene-path argument (matches the
  `godot://scene/current` "currently open" intent). Opening/saving scenes is a later sub-project.
- No reparent / duplicate / rename-as-distinct-tool in v1 (rename is achievable via `modify_node`
  on the `name` property).
- No instancing of PackedScenes as children in v1 (`create_node` creates built-in `Node` classes).

## Out of scope (later sub-projects)

`run_project`/`stop_project`, `get_editor_state`, scene open/save tools, script analysis — these
belong to roadmap sub-projects 3 and 4.
