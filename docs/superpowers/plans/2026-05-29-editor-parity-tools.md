# Editor Parity Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each PR (phase) is a stacked branch — see "Stacking protocol".

**Goal:** Add 21 in-editor tools (+2 enhancements) toward godot-mcp-pro parity, as 5 stacked PRs.

**Architecture:** Each tool is a method on a `tools/*.gd` `RefCounted` returning the `{ok, value/error}` contract, registered in `mcp_handler._build_default_registry()`. Live-editor state is reached only via the `Engine.get_meta("GodotMCPPlugin")` seam, so handlers return a clean error headlessly and stay unit-testable. Mutating node ops are `EditorUndoRedoManager` actions. One new infra file (`output_capture.gd`) wired into the plugin lifecycle.

**Tech Stack:** Pure GDScript (`@tool`), Godot 4.6.x, headless test runner (`run_tests.sh`).

**Spec:** `docs/superpowers/specs/2026-05-29-editor-parity-tools-design.md` (read it first — it records all scope decisions and the verified 4.6 APIs).

---

## Stacking protocol (read once, applies to every PR)

Branches stack linearly. PR1 branches from `feat/scene-tools`; each later PR branches from the previous PR's branch.

```
feat/scene-tools → feat/node-structure-tools (PR1) → feat/node-signals-groups (PR2)
  → feat/script-tools (PR3) → feat/editor-introspection (PR4) → feat/input-map-tools (PR5)
```

For each PR:
1. `git checkout -b <branch> <parent-branch>`
2. TDD each task: write test → run (red) → implement → run (green).
3. Register every new tool in `mcp_handler._build_default_registry()`; keep the tool instance alive with `reg.set_meta("_<key>", instance)`.
4. Run the full suite: `./addons/godot_mcp/run_tests.sh` — must be green.
5. Update README tool count + the parity-mapping table.
6. Commit, `git push -u origin <branch>`, `gh pr create --base <parent-branch>`.

**Contract reminder:** handlers take `(args: Dictionary)`, return `{"ok": true, "value": ...}` or `{"ok": false, "error": String}`. Non-string `value` is JSON-stringified by the registry. Live seams return null headlessly → return a specific error string.

**Undo pattern (symmetric, from `modify_node`):** when `_undo_redo()` is non-null, register `add_do_*`/`add_undo_*` and `commit_action()` (commit runs the do-branch). When null (headless), perform the mutation directly. Capture old state BEFORE building the undo branch.

**Owner rule:** any node added to the tree must have `owner` set to the edited scene root (recursively for subtrees) or it won't serialize into the `.tscn`.

**Test pattern:** mirror `tests/test_scene_tools.gd` — (a) assert each tool errors cleanly with no scene/editor open; (b) test pure helpers against detached node trees built in-test (`_make_tree`). New seams (`_script_editor`, `output_capture` Logger) are tested by direct instantiation.

---

## PR 1 — Node structure (`feat/node-structure-tools`)

**Files:**
- Modify: `addons/godot_mcp/tools/scene_tools.gd` (reuse `_resolve`, `_undo_redo`, `_attach`, `_detach`, `_make_node`, `_apply_props`, `_decode_props`)
- Modify: `addons/godot_mcp/mcp_handler.gd` (register tools)
- Test: `addons/godot_mcp/tests/test_scene_tools.gd` (extend existing suite)
- Modify: `README.md`

### Task 1.1: `create_node` accepts optional `properties` (covers pro `add_node`)

- [ ] **Step 1 — failing test:** in `test_scene_tools.gd`, headless `create_node` with `properties` still errors (no scene). Add a pure-helper test if you factor property application; otherwise assert the no-scene path and rely on existing `_apply_props` tests.
- [ ] **Step 2 — run red:** `godot4 --headless --path . --script addons/godot_mcp/tests/test_scene_tools.gd`
- [ ] **Step 3 — implement:** after attaching the node in `create_node`, if `args` has `properties` (a Dictionary), apply them inside the SAME undo action via the existing decode/`add_do_property` path (or `_apply_props` headlessly). Reuse `_decode_props`; do not duplicate validation.
- [ ] **Step 4 — run green.**
- [ ] **Step 5 — commit:** `feat: create_node accepts optional properties`

### Task 1.2: `duplicate_node`

API: `Node.duplicate(15)` (DUPLICATE_DEFAULT). Must set `owner` recursively to scene root.

- [ ] **Step 1 — failing test:** add `test_duplicate_node_no_scene_open` (asserts `{ok:false}`). Add a pure-helper test for a recursive owner-setter `_set_owner_recursive(node, root)` against a detached tree: build Root→A→B, duplicate A, set owners, assert every duplicated descendant's `owner == root`.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `duplicate_node({path, new_name?})` — resolve node; reject root; `var dup = node.duplicate()`; optional rename; undo action: do = `_attach`-style add under `node.get_parent()` + `_set_owner_recursive(dup, root)` (+`add_do_reference(dup)`), undo = `_detach` + (the freed ref handled by `add_undo_reference`). Return `{path: root.get_path_to(dup)}`. Add helper:
```gdscript
func _set_owner_recursive(node: Node, root: Node) -> void:
	node.owner = root
	for c in node.get_children():
		_set_owner_recursive(c, root)
```
- [ ] **Step 4 — run green.**
- [ ] **Step 5 — commit:** `feat: add duplicate_node scene tool`

### Task 1.3: `move_node` (reparent)

API: `Node.reparent(new_parent, keep_global_transform=true)`.

- [ ] **Step 1 — failing test:** `test_move_node_no_scene_open`; pure test: build Root→[A, B→[]], move A under B, assert A.get_parent()==B and owner still root.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `move_node({path, new_parent_path, keep_global_transform?})` — resolve both; reject moving root or moving into own descendant (check `node.is_ancestor_of(new_parent)`); capture old parent + index; undo do=reparent to new + reset owner, undo=reparent back to old parent at old index + reset owner. Headless: reparent directly.
- [ ] **Step 4 — run green.**
- [ ] **Step 5 — commit:** `feat: add move_node (reparent) scene tool`

### Task 1.4: `rename_node`

- [ ] **Step 1 — failing test:** `test_rename_node_no_scene_open`; pure test: rename a node, assert `node.name`; rename to "" rejected.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `rename_node({path, name})` — reject empty name; capture old name; undo do=set name, undo=restore. Note Godot may suffix duplicate names; return the actual resulting name.
- [ ] **Step 4 — run green.**
- [ ] **Step 5 — commit:** `feat: add rename_node scene tool`

### Task 1.5: Register + README + suite

- [ ] Register `duplicate_node`, `move_node`, `rename_node` in `mcp_handler._build_default_registry()` (the scene instance already stashed via `_scene` meta). Update `create_node` schema to include optional `properties`.
- [ ] Update README: tool count 14→17, add to scenes section.
- [ ] Run `./addons/godot_mcp/run_tests.sh` — all green.
- [ ] Commit `feat: register node-structure tools`; push; `gh pr create --base feat/scene-tools --title "feat: node structure tools (duplicate/move/rename + create_node properties)"`.

---

## PR 2 — Signals, groups, resources, attach (`feat/node-signals-groups`)

**Files:** Modify `scene_tools.gd`, `mcp_handler.gd`, `test_scene_tools.gd`, `README.md`.

### Task 2.1: `get_signals` (read-only)

API: `Object.get_signal_list()`, `Object.get_signal_connection_list(name)`. 4.6 connection dict keys: `signal` (Signal), `callable` (Callable), `flags` (int). Derive target via `callable.get_object()` / `callable.get_method()`.

- [ ] **Step 1 — failing test:** `test_get_signals_no_scene_open`; pure test: build a node, connect a signal to another node's method, call a `_encode_signals(node, root)` helper, assert the connection appears with target path + method.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `get_signals({path})` returns `{path, signals:[{name, args, connections:[{target_path, method, flags}]}]}`. `target_path = root.get_path_to(callable.get_object())` when the target is in-scene; else its class. Read-only (no undo).
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add get_signals scene tool`

### Task 2.2: `connect_signal` / `disconnect_signal`

API: `source.connect(sig, Callable(target, method), Object.CONNECT_PERSIST)` (persist flag = serializes to .tscn). Disconnect = `source.disconnect(sig, callable)`.

- [ ] **Step 1 — failing test:** no-scene errors for both; pure test: connect then assert `source.is_connected(sig, Callable(target, method))`; disconnect then assert not connected.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `connect_signal({from_path, signal, to_path, method, flags?})` — validate `source.has_signal(signal)`; validate target has the method (`target.has_method`); default flag `CONNECT_PERSIST`. Undo do=connect, undo=disconnect. `disconnect_signal({from_path, signal, to_path, method})` — validate currently connected; undo re-connects with persist. First do-op acts on `source` (a scene node) so the manager picks scene history.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add connect_signal/disconnect_signal scene tools`

### Task 2.3: `get_node_groups` / `set_node_groups` / `find_nodes_in_group`

API: `Node.get_groups()`, `add_to_group(g, true)` (persistent), `remove_from_group(g)`, `is_in_group(g)`. `SceneTree.get_nodes_in_group` is running-tree only → walk edited-scene-root subtree.

- [ ] **Step 1 — failing tests:** no-scene errors; pure tests: set groups diffs correctly (adds missing, removes extra); `_find_in_group(root, "g")` walks subtree and returns paths of members.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `get_node_groups({path})`→`{groups:[...]}` (read-only). `set_node_groups({path, groups})` — diff current vs desired; undoable add/remove with `persistent=true`. `find_nodes_in_group({group})` — recursive subtree walk returning `[paths]`. Add `_find_in_group(node, root, group, out)` helper.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add node group tools`

### Task 2.4: `add_resource`

API: `ClassDB.instantiate(type)`; validate `ClassDB.is_parent_class(type, "Resource")`; `node.set(property, res)`. Undo via `add_do_property`/`add_undo_property` capturing old value.

- [ ] **Step 1 — failing test:** no-scene error; pure test: instantiate RectangleShape2D, set on a node property, assert applied; invalid type rejected; non-existent property rejected.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `add_resource({path, property, type, sub_properties?})` — validate type is a Resource and instantiable; validate `property` is in `node.get_property_list()`; instantiate, optionally apply `sub_properties` (reuse `_decode_props`-style on the resource), assign; undoable.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add add_resource scene tool`

### Task 2.5: `set_anchor_preset`

API: `Control.set_anchors_preset(preset, keep_offsets)`. `LayoutPreset` enum (PRESET_FULL_RECT=15, etc. — see spec/research). Accept int or name.

- [ ] **Step 1 — failing test:** no-scene error; non-Control rejected; pure test: name→int resolver (`PRESET_FULL_RECT`→15); applying to a Control sets anchors.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `set_anchor_preset({path, preset, keep_offsets?})` — error if `not node is Control`; resolve preset; capture old anchor_* for undo; apply. Add `_resolve_preset(value)` helper mapping names→ints.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add set_anchor_preset scene tool`

### Task 2.6: `attach_script`

API: validate `script_path` via `Paths.validate`; `node.set_script(load(path))`; undo restores prior script.

- [ ] **Step 1 — failing test:** no-scene error; invalid path rejected; pure test (against detached node): attach a loaded script resource, assert `node.get_script()`; undo helper restores.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `attach_script({path, script_path})` — validate path + file exists; `var scr = load(script_path)`; error if null/not a Script; capture `node.get_script()`; undoable set_script.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add attach_script scene tool`

### Task 2.7: Register + README + PR

- [ ] Register all 9 PR2 tools in `mcp_handler`. Run full suite green. README count 17→26.
- [ ] Commit `feat: register signal/group/resource tools`; push; `gh pr create --base feat/node-structure-tools`.

---

## PR 3 — Script tools (`feat/script-tools`)

**Files:** Modify `tools/script_tools.gd`, `mcp_handler.gd`, `tests/test_script_tools.gd`, `README.md`. Add a `_script_editor()` seam to `script_tools.gd` mirroring `scene_tools._current_script`.

### Task 3.1: `list_scripts`

- [ ] **Step 1 — failing test:** pure test against `examples/` — `list_scripts({path:"res://examples"})` returns entries with `path`; parse `class_name`/`extends` from a fixture. (Headless filesystem walk works without the editor.)
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** recursive `DirAccess` walk for `*.gd` under `path` (default `res://`); for each, read text, regex/scan first non-comment lines for `class_name X` and `extends Y`. Return `[{path, class_name, extends}]`. Reuse `Paths.validate` for `path`.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add list_scripts tool`

### Task 3.2: `get_open_scripts`

API: `EditorInterface.get_script_editor().get_open_scripts()` → Array[Script]; `get_current_script()`.

- [ ] **Step 1 — failing test:** headless → `{ok:true, value:{scripts:[], current:null}}` (no editor). Add `_script_editor()` seam returning null headlessly.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `get_open_scripts({})` — via seam; map to `resource_path`s; mark current. Headless → empty.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add get_open_scripts tool`

### Task 3.3: `edit_script` find/replace mode

- [ ] **Step 1 — failing test:** pure test of a `_apply_edit(src, args)` helper: `{find, replace}` replaces; missing `find` errors; both `content` and `find` → error; neither → error; `find` not present → error; `replace_all` replaces all.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** refactor `edit_script` to branch: if `content` present → overwrite (existing behavior); elif `find` present → read file, check occurrences (error if 0; if >1 require `replace_all`), replace, write; else error. Factor the string logic into `_apply_edit` for testability.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: edit_script supports find/replace mode`

### Task 3.4: Register + README + PR

- [ ] Register `list_scripts`, `get_open_scripts`; update `edit_script` schema (`find`, `replace`, `replace_all` optional). Run full suite green. README count 26→28, mapping table notes `read_script→read_file`, `search_in_files→search_project`.
- [ ] Commit; push; `gh pr create --base feat/node-signals-groups`.

---

## PR 4 — Editor introspection (`feat/editor-introspection`)

**Files:**
- Create: `addons/godot_mcp/tools/output_capture.gd` (Logger ring buffer)
- Create: `addons/godot_mcp/tools/editor_tools.gd`
- Modify: `addons/godot_mcp/mcp_plugin.gd` (install/remove logger; stash in meta)
- Modify: `mcp_handler.gd`, `README.md`
- Test: `addons/godot_mcp/tests/test_editor_tools.gd` (new)

### Task 4.1: `output_capture.gd` ring buffer Logger

API: extend `Logger`; override `_log_message(message, error)` and `_log_error(function, file, line, code, rationale, editor_notify, error_type, script_backtraces)`. Mutex-guard (off-main-thread possible). `error_type`: ERROR_TYPE_SCRIPT=2 etc.

- [ ] **Step 1 — failing test:** instantiate the Logger directly; feed `_log_message("hello", false)` and `_log_error(...)`; assert `entries()` returns them; assert ring eviction past cap (e.g. cap 4, push 6 → 4 newest); `clear()` empties; `errors_only` filter works.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** ring buffer (Array + cap, default 1000), `_mutex := Mutex.new()`; `_log_message`→`{type:"log", text}`; `_log_error`→`{type:"error", line, message, error_type}`; methods `entries(limit:=0, errors_only:=false)`, `clear()`. Do NOT call `print`/`push_error` inside overrides (recursion).
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add output_capture ring-buffer logger`

### Task 4.2: Wire logger into plugin lifecycle

- [ ] **Step 1 — implement:** in `mcp_plugin._enter_tree`: `_capture = OutputCapture.new(); OS.add_logger(_capture); Engine.set_meta("GodotMCPOutputCapture", _capture)`. In `_exit_tree`: `OS.remove_logger(_capture)`, remove meta, null it. (No unit test for lifecycle; verified by full suite still passing + manual E2E.)
- [ ] **Step 2 — run full suite green.** **Step 3 — commit:** `feat: install output capture logger in plugin`

### Task 4.3: `get_output_log` / `clear_output` / `get_editor_errors`

Seam: `_capture()` returns `Engine.get_meta("GodotMCPOutputCapture")` or null headlessly.

- [ ] **Step 1 — failing tests:** headless (no meta) → `get_output_log` returns `{entries:[]}`; `clear_output` returns ok; `get_editor_errors` returns `{errors:[]}`. (Inject a fake capture via meta in-test to assert pass-through, then remove it.)
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `get_output_log({limit?, errors_only?})`, `clear_output({})` (clears buffer; document it does NOT clear the editor dock), `get_editor_errors({limit?})` (entries filtered to errors). All degrade to empty/ok headlessly.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add output log + editor errors tools`

### Task 4.4: `get_editor_screenshot`

API (windowed): `base_control.get_viewport().get_texture().get_image().save_png_to_buffer()` → base64. Headless → error (D9).

- [ ] **Step 1 — failing test:** headless → `{ok:false, error:"Screenshots require a windowed editor"}` (no plugin meta or no viewport image).
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `get_editor_screenshot({path?})` — via plugin seam get base control viewport image; if null/headless → the error above; else if `path` given (validate res://) save PNG and return `{path}`; else return `{png_base64: Marshalls.raw_to_base64(bytes)}`.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add get_editor_screenshot tool`

### Task 4.5: `reload_project`

API: `EditorInterface.get_resource_filesystem().scan()` + reload open scripts.

- [ ] **Step 1 — failing test:** headless → `{ok:true, value:{reloaded:false}}` (no editor; no-op). 
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** via seam, call `get_resource_filesystem().scan()`; return `{reloaded: true}` live, `false` headless.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add reload_project tool`

### Task 4.6: Register + README + PR

- [ ] Register the 5 editor tools (stash `editor_tools` instance via meta). Run full suite green. README count 28→33; add an "Editor" section; document the `clear_output`/screenshot limitations and that `reload_plugin` is deferred (with rationale).
- [ ] Commit; push; `gh pr create --base feat/script-tools`.

---

## PR 5 — Input map (`feat/input-map-tools`)

**Files:** Create `addons/godot_mcp/tools/input_tools.gd`; modify `mcp_handler.gd`, `README.md`; create `tests/test_input_tools.gd`.

### Task 5.1: `get_input_actions`

API: enumerate `ProjectSettings.get_property_list()` for names starting `input/`; each `{deadzone, events:[InputEvent]}`.

- [ ] **Step 1 — failing test:** call `get_input_actions({})`, assert it returns a list (default project has `input/ui_accept` etc.); each entry has `name` and `events`.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** iterate settings under `input/`; for each, read the dict, encode `events` with `var_to_str`. Return `[{name, deadzone, events:[var_str]}]`.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add get_input_actions tool`

### Task 5.2: `set_input_action`

API: `ProjectSettings.set_setting("input/<name>", {deadzone, events})`; `ProjectSettings.save()`. Events parsed from var_str via `str_to_var`.

- [ ] **Step 1 — failing test:** set a temp action `input/_mcp_test`, read it back via `get_input_actions`, assert present; then clear it (`set_setting(name, null)`) in teardown. Validate empty name rejected.
- [ ] **Step 2 — run red.**
- [ ] **Step 3 — implement:** `set_input_action({name, events?, deadzone?})` — validate name; build `{deadzone: deadzone (default 0.5), events: [parsed InputEvents]}`; merge with existing if partial; `set_setting` + `save()`. Return the resulting action.
- [ ] **Step 4 — run green.** **Step 5 — commit:** `feat: add set_input_action tool`

### Task 5.3: Register + README + PR

- [ ] Register both tools (stash `input_tools` meta). Run full suite green. README count 33→35; add "Input map" section.
- [ ] Commit; push; `gh pr create --base feat/editor-introspection`.

---

## Self-review notes

- **Spec coverage:** every PR2/PR4 spec tool maps to a task; mapped-not-built tools (read_script, search_in_files) and deferred tools (execute_editor_script, reload_plugin, running-game) are documented, not tasked. ✓
- **Counts:** 14 → 17 (PR1: +3) → 26 (PR2: +9) → 28 (PR3: +2) → 33 (PR4: +5) → 35 (PR5: +2). Matches spec's 21 new tools + 2 enhancements. ✓
- **Headless honesty:** every live tool has a defined headless return. ✓
