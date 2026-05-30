# Project & Resources — Design Spec

**Date:** 2026-05-29
**Status:** Approved (brainstorming complete)
**Sub-project:** 1 of 4 in the "feature-parity" roadmap (see Roadmap below).

## Goal

Add project-introspection capability and introduce the MCP **resource** layer to the
Godot MCP server. This is the smallest, safest, fully-headless-testable slice of the
larger feature-parity effort, and it establishes the resource pattern that later
sub-projects (`script/current`, `scene/current`) will reuse.

Everything here works **headless**: `ProjectSettings`, `Engine.get_version_info()`,
and `DirAccess` need no live editor. The clean unit-test story is preserved.

## Roadmap context (decomposition)

The full target feature set was decomposed into four sequenced sub-projects:

1. **Project & Resources** *(this spec)* — `get_project_settings`, `list_project_resources`,
   `get_project_info`, `godot://project/info` resource, and the MCP resource layer.
2. **Scene & Node tools** — read/create/save scenes, scene-tree, node CRUD. Contains the
   central live-editor-vs-disk architectural fork.
3. **Editor control & live "current" resources** — `run_project`, `stop_project`,
   `get_editor_state`, `godot://script/current`, `godot://scene/current`. Requires the
   live-editor seam; not headless-testable.
4. **Script polish** — `list_project_scripts`, `analyze_script`, naming reconciliation.

## Architecture

### New MCP resource layer

Three additions to `mcp_handler.gd`, parallel to the existing tool handling:

- **`initialize` capabilities** gain `"resources": {}` alongside `"tools": {}`.
- **`resources/list`** → `JsonRpc.result(id, {"resources": registry.list_resources()})`.
- **`resources/read`** (params `{uri}`) → `JsonRpc.result(id, registry.read_resource(uri))`,
  where the result is the MCP shape `{contents: [{uri, mimeType, text}]}`.

Unknown URI on `resources/read` → JSON-RPC error (`-32602`, "Unknown resource: <uri>").

### `ResourceRegistry` (mirrors `ToolRegistry`)

A new `RefCounted` at `addons/godot_mcp/resource_registry.gd`, deliberately symmetric
with `tool_registry.gd`:

- Entries: `{uri, name, description, mimeType, handler: Callable}`.
- `register(uri, name, description, mime_type, handler)`.
- `list_resources()` → array of `{uri, name, description, mimeType}` descriptors
  (no `handler`, no result payload).
- `read_resource(uri)` → calls the handler with `{}` (resources take no args in v1),
  adapts the internal contract into `{contents: [{uri, mimeType, text}]}`.

**Handler contract** mirrors tools exactly: `(args: Dictionary) -> {"ok": bool, "value": ...}`
on success or `{"ok": false, "error": String}` on failure. Non-string `value` is
`JSON.stringify`'d into the `text` field (same rule the tool registry already uses).

`mcp_handler._build_default_resource_registry()` builds it parallel to the tool one,
stashing tool instances via `set_meta` so they survive GC (same idiom as `_files`/`_scripts`).

## Components shipped

### Tool: `get_project_settings`
Args: `{key?: string, prefix?: string}` (object schema; no required fields).
- `key` present → `{value}` for that single setting; error if it does not exist.
- `prefix` present → object map of all **author-set** keys under that prefix.
- neither → object map of **all author-set** (non-default) settings.

*Author-set* = the settings actually overridden in `project.godot`, not engine defaults.
Implementation: iterate `ProjectSettings.get_property_list()`, keep entries that
`ProjectSettings.has_setting(name)` and are not at their default. The exact "is-default"
test (e.g. `ProjectSettings.property_can_revert(name)` / comparing to
`property_get_revert(name)`) is confirmed against the Godot 4.6 API during implementation.

### Tool: `list_project_resources`
Args: `{path?: string}` — defaults to `res://`; runs through `utils/paths.gd` `validate()`.
- Recursively walks the directory tree via `DirAccess`.
- Returns `{entries: [{path, type}]}` for every `.tres`, `.res`, and `.tscn` file.
  (Scenes are PackedScene resources, so they are included.)
- `type` = resource/root class name. Obtained **without `load()`** — use
  `ResourceLoader.exists`/a lightweight type read (parse the `type=`/`[gd_resource type=...]`
  header, or `ResourceLoader.get_resource_type(path)` if available in 4.6). No full load,
  to avoid pulling in dependencies and slow IO.

### Tool: `get_project_info` + Resource: `godot://project/info`
Both serve the **same curated metadata** via shared logic (one method, registered as a
tool and wired into the resource registry). `mimeType` for the resource: `application/json`.

Curated payload:
```json
{
  "name": "<application/config/name>",
  "description": "<application/config/description, omitted if empty>",
  "version": "<application/config/version, omitted if empty>",
  "main_scene": "<application/run/main_scene>",
  "icon": "<application/config/icon>",
  "features": ["<application/config/features ...>"],
  "godot_version": "<Engine.get_version_info().string>",
  "autoloads": [{"name": "...", "path": "res://...", "singleton": true}]
}
```
Autoloads are parsed from the `autoload/*` settings. Empty optional fields are omitted.

## File layout

- `addons/godot_mcp/resource_registry.gd` — new, mirrors `tool_registry.gd`.
- `addons/godot_mcp/tools/project_tools.gd` — new; `get_project_settings`,
  `list_project_resources`, `get_project_info` handlers.
- `addons/godot_mcp/mcp_handler.gd` — edited: resource capability, `resources/list`,
  `resources/read`, `_build_default_resource_registry()`, register project tools.

## Naming

Target spec uses kebab-case (`get-project-settings`); we use the established snake_case
house style: `get_project_settings`, `list_project_resources`, `get_project_info`.

## Error handling

- Same `{ok, error}` contract throughout; `tool_registry`/`resource_registry` translate.
- `get_project_settings` with a missing `key` → `{ok:false, error:"Setting not found: <key>"}`.
- `resources/read` with an unknown URI → JSON-RPC error `-32602`.
- `list_project_resources` with a path failing `validate()` → `{ok:false, error:...}`
  (path safety per CLAUDE.md).

## Testing

All headless. New suites under `addons/godot_mcp/tests/` following `test_case.gd`:

- **`test_resource_registry.gd`** — register/list/read; non-string value gets JSON-stringified;
  unknown URI handling.
- **`test_project_tools.gd`** — `get_project_settings` (key / prefix / all author-set / missing key);
  `list_project_resources` walks a fixture tree and returns only `.tres`/`.res`/`.tscn` with
  correct `type`, respects `path`, rejects traversal; `get_project_info` returns curated shape
  with autoloads and omits empty optionals.
- **`test_mcp_handler.gd`** (extend existing) — `initialize` advertises `resources` capability;
  `resources/list` returns the project/info descriptor; `resources/read` of
  `godot://project/info` returns `{contents:[{uri,mimeType,text}]}`; unknown URI → error.

Fixtures: add a couple of `.tres`/`.tscn` files (or a temp dir created in-test, matching the
existing `_scripttools_test/` pattern) under `examples/` or a test-created scratch dir.

## Out of scope

`script/current`, `scene/current` resources (need live editor — sub-project 3); any scene/node
tooling; editor/run control; script listing/analysis.
