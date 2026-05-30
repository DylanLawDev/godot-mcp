# Scene + UID Tools Design

**Date:** 2026-05-29
**Status:** Approved (brainstorming)

## Motivation

Comparing against [Coding-Solo/godot-mcp](https://github.com/Coding-Solo/godot-mcp): most of its scene tools shell out to a *headless* Godot process running a bundled `godot_operations.gd`. Our server is a live editor plugin, so we already do scene editing live and better. The genuine capability gaps that need **no launched process** are scene file creation, scene persistence, and UID management. This spec covers four new tools:

- `create_scene` — create a new `.tscn` with a root node, on disk.
- `save_scene` — persist the open edited scene, or pack it to a new file (variant).
- `get_uid` — resolve a resource path to its `uid://` string.
- `update_project_uids` — resave resources under a path to regenerate UID sidecars/refs.

Explicitly **out of scope** (deferred): `export_mesh_library`, `get_godot_version`, `load_sprite`, and anything needing a launched game (`run_project`/`get_debug_output`/`stop_project`, already out per v1 scope).

## Architecture / placement

Approach A (chosen): theme-based placement.

- `create_scene` + `save_scene` live in existing `tools/scene_tools.gd` — they are scene authoring, and `save_scene` needs that file's live helpers (`_edited_scene_root()`, `_rescan_filesystem()`).
- `get_uid` + `update_project_uids` live in a new `tools/uid_tools.gd` (resource/project-level), with its own test file. New instance stashed via `reg.set_meta("_uids", …)` so it isn't GC'd (same pattern as `_files`/`_scripts`).

All four follow the standard tool result contract: `{"ok": true, "value": …}` / `{"ok": false, "error": String}`. All user paths go through `utils/paths.gd` `validate()`.

## Tool surface

### `create_scene` (scene_tools.gd)
- **Args:** `{path, root_type, root_name?, overwrite?}`
- `path` validated, must end `.tscn`. `root_type` validated via existing `_make_node()` helper (reuses its invalid-type error). `root_name` defaults to `root_type`. `overwrite` defaults `false` → **error if the file already exists**.
- Builds root node → `PackedScene.pack()` → `ResourceSaver.save()` → `_rescan_filesystem()`.
- **Returns:** `{ok, value:{path, root_type, root_name, uid}}` (uid read back after save).
- Needs no edited-scene-root → **fully headlessly testable**.

### `save_scene` (scene_tools.gd)
- **Args:** `{path?}`
- No `path` → save open edited scene to its own file via `EditorInterface.save_scene()`. If the open scene has no file path yet, error: *"current scene has no path; pass {path} to save as a variant."*
- With `path` ("variant") → validate, pack current edited tree, `ResourceSaver.save()` to new path, rescan. Does **not** change which scene is open.
- **Returns:** `{ok, value:{path, variant: bool}}`.
- Requires `_edited_scene_root()` → **live-only**; headless tests cover the "no scene open" guard and arg validation only.

### `get_uid` (uid_tools.gd)
- **Args:** `{path}` → validate, file must exist. `id = ResourceLoader.get_resource_uid(path)`; if `INVALID_ID` → error *"No UID for &lt;path&gt;"*.
- **Returns:** `{ok, value:{path, uid}}`, uid = `ResourceUID.id_to_text(id)`.
- **Fully headlessly testable** (use `examples/` fixtures).

### `update_project_uids` (uid_tools.gd)
- **Args:** `{path?}` default `res://` → validate. Recursively walks for `.tscn`/`.tres`/`.res`, skipping hidden dirs (`.godot`) and symlinked dirs (matching the `list_scripts` convention). Each file: `load()` then `ResourceSaver.save()` back to the same path.
- Per-file failures collected, **not fatal** (matches the recent "report failures, keep going" convention).
- **Returns:** `{ok, value:{scanned, resaved, failed:[{path, error}]}}`.
- **Fully headlessly testable.**

## Error handling

- All paths via `Paths.validate()` (rejects `..` traversal, normalizes to `res://`).
- `create_scene`: refuse overwrite by default; invalid `root_type` and non-`.tscn` path error before any write.
- `save_scene`: never-saved scene errors rather than silently requiring a path.
- `update_project_uids`: load/save failures per file are captured in `failed[]`; the call still succeeds with counts.

## Testing plan (TDD — tests first)

**New `tests/test_uid_tools.gd` (fully headless):**
- `get_uid`: valid `.tscn` fixture → `uid://…`; `.tres` fixture; nonexistent path errors; traversal rejected; no-UID file errors cleanly.
- `update_project_uids`: temp dir of fixtures → asserts `scanned`/`resaved` counts; a deleted `.uid` sidecar reappears; a corrupt resource lands in `failed[]` while siblings resave; default path walks `res://`; hidden/symlinked dirs skipped.

**Extend `tests/test_scene_tools.gd`:**
- `create_scene` (headless meat): `Node2D`-rooted `.tscn` at a temp path → file exists, reloads, root name/type correct, `uid` returned; invalid `root_type` errors; existing file without `overwrite` errors; with `overwrite:true` succeeds; non-`.tscn` path errors; traversal rejected; temp files cleaned up.
- `save_scene` (headless guard only): no scene open → error for both no-arg and `{path}` forms; invalid `path` rejected.

## Registry wiring

- Register all four in `mcp_handler._build_default_registry()`. `create_scene`/`save_scene` bind to the existing `_scene` instance; new `uid_tools` instance via `reg.set_meta("_uids", …)`.
- Update CLAUDE.md tool count/list and `## Scope` section.

## Delivery: stacked PRs

Three stacked PRs (each branches off the previous), TDD within each:

1. **uid-tools** — `uid_tools.gd` + tests + wiring. Independent, fully headless.
2. **create-scene** — stacked on #1; `create_scene` + tests + wiring.
3. **save-scene** — stacked on #2; `save_scene` + tests + wiring; CLAUDE.md scope update.

Each PR opened for Codex review. Per project convention, post a review-trail comment on each PR summarizing findings/fixes.
