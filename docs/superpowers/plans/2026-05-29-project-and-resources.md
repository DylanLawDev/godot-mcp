# Project & Resources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add project-introspection tools (`get_project_settings`, `list_project_resources`, `get_project_info`) and introduce the MCP **resource** layer, serving `godot://project/info`.

**Architecture:** A new `ResourceRegistry` (`RefCounted`) mirrors the existing `ToolRegistry`. `mcp_handler.gd` gains `resources/list` + `resources/read` dispatch and advertises the `resources` capability. A new `tools/project_tools.gd` holds the three handlers, all reading from `ProjectSettings` / a `ConfigFile` view of `project.godot` / `DirAccess` — fully headless.

**Tech Stack:** Pure GDScript (`@tool`), Godot 4.6.x, headless `SceneTree` test harness (`tests/test_case.gd`).

**Spec:** `docs/superpowers/specs/2026-05-29-project-and-resources-design.md`

**Conventions (from CLAUDE.md):**
- Tool/resource handler contract: `(args: Dictionary) -> {"ok": bool, "value": ...}` or `{"ok": false, "error": String}`.
- All addon scripts start with `@tool`. Test scripts do **not**.
- Reference runtime classes via `const X = preload("res://...")`. No `class_name`.
- Path args run through `utils/paths.gd` `validate()`.
- `docs/superpowers/` is gitignored — commits in this plan only touch `addons/` (and `README.md`/`CLAUDE.md` in the final task).

**Run a single suite:** `godot4 --headless --path . --script addons/godot_mcp/tests/<file>.gd`
**Run all:** `./addons/godot_mcp/run_tests.sh` (auto-discovers every `test_*.gd`).

---

## File Structure

- **Create** `addons/godot_mcp/resource_registry.gd` — registry for MCP resources (mirror of `tool_registry.gd`).
- **Create** `addons/godot_mcp/tools/project_tools.gd` — `get_project_settings`, `list_project_resources`, `get_project_info` + private helpers.
- **Create** `addons/godot_mcp/tests/test_resource_registry.gd` — unit tests for the registry.
- **Create** `addons/godot_mcp/tests/test_project_tools.gd` — unit tests for the three handlers.
- **Modify** `addons/godot_mcp/mcp_handler.gd` — resources capability, `resources/list`/`resources/read`, `_build_default_resource_registry()`, register project tools.
- **Modify** `addons/godot_mcp/tests/test_mcp_handler.gd` — assert resource capability + list/read round-trip.
- **Modify** `README.md`, `CLAUDE.md` — bump tool count and note the resource layer (final task).

---

## Task 1: ResourceRegistry

**Files:**
- Create: `addons/godot_mcp/resource_registry.gd`
- Test: `addons/godot_mcp/tests/test_resource_registry.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_resource_registry.gd`:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const ResourceRegistry = preload("res://addons/godot_mcp/resource_registry.gd")

# A stand-in handler object. Returns a fixed contract result.
class _Stub:
	var _result: Dictionary
	func _init(result: Dictionary) -> void:
		_result = result
	func handle(_args: Dictionary) -> Dictionary:
		return _result

func test_list_resources_returns_descriptors_without_handler() -> void:
	var reg = ResourceRegistry.new()
	var stub = _Stub.new({"ok": true, "value": "x"})
	reg.register("godot://a", "a_name", "desc", "application/json", Callable(stub, "handle"))
	var listed: Array = reg.list_resources()
	assert_eq(listed.size(), 1)
	assert_eq(listed[0]["uri"], "godot://a")
	assert_eq(listed[0]["name"], "a_name")
	assert_eq(listed[0]["mimeType"], "application/json")
	assert_false(listed[0].has("handler"))

func test_has_reports_registration() -> void:
	var reg = ResourceRegistry.new()
	reg.register("godot://a", "a", "d", "text/plain", Callable(_Stub.new({"ok": true, "value": ""}), "handle"))
	assert_true(reg.has("godot://a"))
	assert_false(reg.has("godot://missing"))

func test_read_resource_string_value_passes_through() -> void:
	var reg = ResourceRegistry.new()
	reg.register("godot://a", "a", "d", "text/plain", Callable(_Stub.new({"ok": true, "value": "hello"}), "handle"))
	var out: Dictionary = reg.read_resource("godot://a")
	assert_eq(out["contents"][0]["uri"], "godot://a")
	assert_eq(out["contents"][0]["mimeType"], "text/plain")
	assert_eq(out["contents"][0]["text"], "hello")

func test_read_resource_non_string_value_is_json_stringified() -> void:
	var reg = ResourceRegistry.new()
	reg.register("godot://a", "a", "d", "application/json", Callable(_Stub.new({"ok": true, "value": {"k": 1}}), "handle"))
	var out: Dictionary = reg.read_resource("godot://a")
	var parsed = JSON.parse_string(out["contents"][0]["text"])
	assert_eq(parsed["k"], 1)

func test_read_resource_error_returns_error_text() -> void:
	var reg = ResourceRegistry.new()
	reg.register("godot://a", "a", "d", "text/plain", Callable(_Stub.new({"ok": false, "error": "boom"}), "handle"))
	var out: Dictionary = reg.read_resource("godot://a")
	assert_eq(out["contents"][0]["text"], "boom")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_resource_registry.gd`
Expected: FAIL — `resource_registry.gd` does not exist (parse/preload error, non-zero exit).

- [ ] **Step 3: Write minimal implementation**

Create `addons/godot_mcp/resource_registry.gd`:

```gdscript
@tool
extends RefCounted

var _resources: Array = []  # each: {uri, name, description, mimeType, handler: Callable}

func register(uri: String, name: String, description: String, mime_type: String, handler: Callable) -> void:
	_resources.append({
		"uri": uri,
		"name": name,
		"description": description,
		"mimeType": mime_type,
		"handler": handler,
	})

# Descriptors only — the shape MCP resources/list expects.
func list_resources() -> Array:
	var out := []
	for r in _resources:
		out.append({
			"uri": r["uri"],
			"name": r["name"],
			"description": r["description"],
			"mimeType": r["mimeType"],
		})
	return out

func has(uri: String) -> bool:
	for r in _resources:
		if r["uri"] == uri:
			return true
	return false

# Returns the MCP resources/read result: {contents: [{uri, mimeType, text}]}.
func read_resource(uri: String) -> Dictionary:
	for r in _resources:
		if r["uri"] == uri:
			var res: Dictionary = r["handler"].call({})
			var text: String
			if res.get("ok", false):
				var val = res.get("value")
				text = val if typeof(val) == TYPE_STRING else JSON.stringify(val)
			else:
				text = str(res.get("error", "unknown error"))
			return {"contents": [{"uri": uri, "mimeType": r["mimeType"], "text": text}]}
	return {"contents": []}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_resource_registry.gd`
Expected: PASS — `=== 6 passed, 0 failed (test_resource_registry.gd) ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/resource_registry.gd addons/godot_mcp/tests/test_resource_registry.gd
git commit -m "feat: add ResourceRegistry mirroring ToolRegistry"
```

---

## Task 2: project_tools — get_project_info

**Files:**
- Create: `addons/godot_mcp/tools/project_tools.gd`
- Test: `addons/godot_mcp/tests/test_project_tools.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_project_tools.gd`:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const ProjectTools = preload("res://addons/godot_mcp/tools/project_tools.gd")

func test_get_project_info_has_name_and_godot_version() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_info({})
	assert_true(r["ok"])
	var info: Dictionary = r["value"]
	# project.godot sets application/config/name = "Godot MCP".
	assert_eq(info["name"], "Godot MCP")
	assert_ne(str(info["godot_version"]), "")
	assert_true(info.has("autoloads"))
	assert_true(info.has("features"))

func test_get_project_info_omits_empty_optionals() -> void:
	var pt = ProjectTools.new()
	var info: Dictionary = pt.get_project_info({})["value"]
	# project.godot defines no description/version → keys omitted.
	assert_false(info.has("description"))
	assert_false(info.has("version"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_project_tools.gd`
Expected: FAIL — `project_tools.gd` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `addons/godot_mcp/tools/project_tools.gd`:

```gdscript
@tool
extends RefCounted

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

func get_project_info(_args: Dictionary) -> Dictionary:
	return {"ok": true, "value": _project_info()}

func _project_info() -> Dictionary:
	var info := {}
	info["name"] = str(ProjectSettings.get_setting("application/config/name", ""))
	var desc := str(ProjectSettings.get_setting("application/config/description", ""))
	if desc != "":
		info["description"] = desc
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	if ver != "":
		info["version"] = ver
	var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene != "":
		info["main_scene"] = main_scene
	var icon := str(ProjectSettings.get_setting("application/config/icon", ""))
	if icon != "":
		info["icon"] = icon
	info["features"] = ProjectSettings.get_setting("application/config/features", PackedStringArray())
	info["godot_version"] = Engine.get_version_info().get("string", "")
	info["autoloads"] = _autoloads()
	return info

func _autoloads() -> Array:
	var out := []
	var cfg := ConfigFile.new()
	if cfg.load("res://project.godot") != OK:
		return out
	if not cfg.has_section("autoload"):
		return out
	for name in cfg.get_section_keys("autoload"):
		var raw := str(cfg.get_value("autoload", name, ""))
		var singleton := raw.begins_with("*")
		var path := raw.substr(1) if singleton else raw
		out.append({"name": name, "path": path, "singleton": singleton})
	return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_project_tools.gd`
Expected: PASS — `=== 4 passed, 0 failed (test_project_tools.gd) ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/tools/project_tools.gd addons/godot_mcp/tests/test_project_tools.gd
git commit -m "feat: add get_project_info project tool"
```

---

## Task 3: project_tools — get_project_settings

**Files:**
- Modify: `addons/godot_mcp/tools/project_tools.gd`
- Test: `addons/godot_mcp/tests/test_project_tools.gd`

- [ ] **Step 1: Write the failing test**

Append to `addons/godot_mcp/tests/test_project_tools.gd`:

```gdscript
func test_get_project_settings_all_author_set() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_settings({})
	assert_true(r["ok"])
	var settings: Dictionary = r["value"]
	assert_eq(settings["application/config/name"], "Godot MCP")
	# Engine defaults are NOT included (only project.godot entries).
	assert_false(settings.has("physics/common/physics_ticks_per_second"))

func test_get_project_settings_single_key() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_settings({"key": "application/config/name"})
	assert_true(r["ok"])
	assert_eq(r["value"]["value"], "Godot MCP")

func test_get_project_settings_missing_key_errors() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_settings({"key": "no/such/setting"})
	assert_false(r["ok"])
	assert_true(str(r["error"]).begins_with("Setting not found"))

func test_get_project_settings_prefix_filter() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.get_project_settings({"prefix": "application/"})
	assert_true(r["ok"])
	var settings: Dictionary = r["value"]
	assert_true(settings.has("application/config/name"))
	for k in settings:
		assert_true(str(k).begins_with("application/"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_project_tools.gd`
Expected: FAIL — `get_project_settings` method does not exist (call returns error / suite reports failures).

- [ ] **Step 3: Write minimal implementation**

Add to `addons/godot_mcp/tools/project_tools.gd` (after `get_project_info`):

```gdscript
func get_project_settings(args: Dictionary) -> Dictionary:
	var settings := _author_settings()
	if settings.is_empty():
		return {"ok": false, "error": "Cannot load project.godot"}
	var key := str(args.get("key", ""))
	if key != "":
		if not settings.has(key):
			return {"ok": false, "error": "Setting not found: " + key}
		return {"ok": true, "value": {"value": settings[key]}}
	var prefix := str(args.get("prefix", ""))
	if prefix != "":
		var filtered := {}
		for k in settings:
			if str(k).begins_with(prefix):
				filtered[k] = settings[k]
		return {"ok": true, "value": filtered}
	return {"ok": true, "value": settings}

# Author-set settings = exactly what's written in project.godot (no engine defaults).
func _author_settings() -> Dictionary:
	var out := {}
	var cfg := ConfigFile.new()
	if cfg.load("res://project.godot") != OK:
		return out
	for section in cfg.get_sections():
		for k in cfg.get_section_keys(section):
			var full_key := (section + "/" + k) if section != "" else k
			out[full_key] = cfg.get_value(section, k)
	return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_project_tools.gd`
Expected: PASS — `=== 8 passed, 0 failed (test_project_tools.gd) ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/tools/project_tools.gd addons/godot_mcp/tests/test_project_tools.gd
git commit -m "feat: add get_project_settings project tool"
```

---

## Task 4: project_tools — list_project_resources

**Files:**
- Modify: `addons/godot_mcp/tools/project_tools.gd`
- Test: `addons/godot_mcp/tests/test_project_tools.gd`

- [ ] **Step 1: Write the failing test**

Append to `addons/godot_mcp/tests/test_project_tools.gd`:

```gdscript
# Creates a scratch fixture tree, runs the body, then removes it.
func _with_resource_fixtures(body: Callable) -> void:
	var base := "res://_project_tools_test"
	DirAccess.make_dir_recursive_absolute(base)
	DirAccess.make_dir_recursive_absolute(base + "/nested")
	var tres := FileAccess.open(base + "/env.tres", FileAccess.WRITE)
	tres.store_string('[gd_resource type="Environment" format=3]\n\n[resource]\n')
	tres = null
	var scn := FileAccess.open(base + "/nested/level.tscn", FileAccess.WRITE)
	scn.store_string("[gd_scene format=3]\n")
	scn = null
	var gd := FileAccess.open(base + "/script.gd", FileAccess.WRITE)
	gd.store_string("extends Node\n")
	gd = null
	var txt := FileAccess.open(base + "/notes.txt", FileAccess.WRITE)
	txt.store_string("hi\n")
	txt = null
	body.call()
	for p in ["env.tres", "nested/level.tscn", "script.gd", "notes.txt"]:
		DirAccess.remove_absolute(base + "/" + p)
	DirAccess.remove_absolute(base + "/nested")
	DirAccess.remove_absolute(base)

func test_list_project_resources_filters_and_types() -> void:
	_with_resource_fixtures(func ():
		var pt = ProjectTools.new()
		var r: Dictionary = pt.list_project_resources({"path": "_project_tools_test"})
		assert_true(r["ok"])
		var entries: Array = r["value"]["entries"]
		var by_path := {}
		for e in entries:
			by_path[e["path"]] = e["type"]
		# .gd and .txt are excluded.
		assert_eq(entries.size(), 2)
		assert_eq(by_path["res://_project_tools_test/env.tres"], "Environment")
		assert_eq(by_path["res://_project_tools_test/nested/level.tscn"], "PackedScene")
	)

func test_list_project_resources_rejects_traversal() -> void:
	var pt = ProjectTools.new()
	var r: Dictionary = pt.list_project_resources({"path": "../escape"})
	assert_false(r["ok"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_project_tools.gd`
Expected: FAIL — `list_project_resources` method does not exist.

- [ ] **Step 3: Write minimal implementation**

Add to `addons/godot_mcp/tools/project_tools.gd`:

```gdscript
const _RESOURCE_EXTS := ["tres", "res", "tscn"]

func list_project_resources(args: Dictionary) -> Dictionary:
	var root := str(args.get("path", "res://"))
	var v := Paths.validate(root)
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var entries := []
	_collect_resources(v["path"], entries)
	return {"ok": true, "value": {"entries": entries}}

func _collect_resources(dir_path: String, entries: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var child := dir_path.path_join(name)
		if d.current_is_dir():
			_collect_resources(child, entries)
		elif name.get_extension() in _RESOURCE_EXTS:
			entries.append({"path": child, "type": _resource_type(child)})
		name = d.get_next()
	d.list_dir_end()

# Determine the resource/root class without load() — parse the text header.
func _resource_type(path: String) -> String:
	if path.get_extension() == "tscn":
		return "PackedScene"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "Resource"
	var first := f.get_line()
	f = null
	# Header looks like: [gd_resource type="Foo" load_steps=.. format=..]
	var marker := 'type="'
	var idx := first.find(marker)
	if idx == -1:
		return "Resource"
	var start := idx + marker.length()
	var end := first.find('"', start)
	if end == -1:
		return "Resource"
	return first.substr(start, end - start)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_project_tools.gd`
Expected: PASS — `=== 10 passed, 0 failed (test_project_tools.gd) ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/tools/project_tools.gd addons/godot_mcp/tests/test_project_tools.gd
git commit -m "feat: add list_project_resources project tool"
```

---

## Task 5: Wire project tools + resource layer into mcp_handler

**Files:**
- Modify: `addons/godot_mcp/mcp_handler.gd`
- Test: `addons/godot_mcp/tests/test_mcp_handler.gd`

- [ ] **Step 1: Write the failing test**

Append to `addons/godot_mcp/tests/test_mcp_handler.gd`:

```gdscript
func test_initialize_advertises_resources_capability() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":10,"method":"initialize","params":{}}'))
	assert_true(d["result"]["capabilities"].has("resources"))

func test_tools_list_includes_project_tools() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":11,"method":"tools/list","params":{}}'))
	var names := []
	for t in d["result"]["tools"]:
		names.append(t["name"])
	for expected in ["get_project_settings", "list_project_resources", "get_project_info"]:
		assert_has(names, expected)

func test_resources_list_includes_project_info() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":12,"method":"resources/list","params":{}}'))
	var uris := []
	for r in d["result"]["resources"]:
		uris.append(r["uri"])
	assert_has(uris, "godot://project/info")

func test_resources_read_project_info_round_trip() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":13,"method":"resources/read","params":{"uri":"godot://project/info"}}'))
	var c = d["result"]["contents"][0]
	assert_eq(c["uri"], "godot://project/info")
	assert_eq(c["mimeType"], "application/json")
	var info = JSON.parse_string(c["text"])
	assert_eq(info["name"], "Godot MCP")

func test_resources_read_unknown_uri_errors() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":14,"method":"resources/read","params":{"uri":"godot://nope"}}'))
	assert_eq(d["error"]["code"], -32602)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_mcp_handler.gd`
Expected: FAIL — no `resources` capability, `resources/list` returns method-not-found (-32601), project tools absent.

- [ ] **Step 3: Write minimal implementation**

In `addons/godot_mcp/mcp_handler.gd`:

(a) Add preloads after the existing `ScriptTools` const (line 7):

```gdscript
const ProjectTools = preload("res://addons/godot_mcp/tools/project_tools.gd")
const ResourceRegistry = preload("res://addons/godot_mcp/resource_registry.gd")
```

(b) Replace the `_registry` field + `_init` (lines 13-16) with:

```gdscript
var _registry
var _resources

func _init(registry = null, resources = null) -> void:
	_registry = registry if registry != null else _build_default_registry()
	_resources = resources if resources != null else _build_default_resource_registry()
```

(c) In `initialize` (the `result` dict, line 39), change the capabilities line to:

```gdscript
				"capabilities": {"tools": {}, "resources": {}},
```

(d) Add two match arms in `_handle`, right after the `"tools/call"` arm (after line 50):

```gdscript
			"resources/list":
				return JsonRpc.result(id, {"resources": _resources.list_resources()})
			"resources/read":
				var rp: Dictionary = req["params"]
				var uri := str(rp.get("uri", ""))
				if not _resources.has(uri):
					return JsonRpc.error(id, -32602, "Unknown resource: " + uri)
				return JsonRpc.result(id, _resources.read_resource(uri))
```

(e) In `_build_default_registry`, register the three project tools before the `set_meta` lines (after line 77), and stash the instance:

```gdscript
	var project = ProjectTools.new()
	reg.register("get_project_settings", "Get author-set project settings. Args: {key?, prefix?}.",
		{"type": "object", "properties": {"key": {"type": "string"}, "prefix": {"type": "string"}}},
		Callable(project, "get_project_settings"))
	reg.register("list_project_resources", "List Godot resource files (.tres/.res/.tscn). Args: {path?}.",
		{"type": "object", "properties": {"path": {"type": "string"}}},
		Callable(project, "list_project_resources"))
	reg.register("get_project_info", "Get curated project metadata (name, version, autoloads, ...). No args.",
		{"type": "object", "properties": {}},
		Callable(project, "get_project_info"))
	reg.set_meta("_project", project)
```

(f) Add a new builder method at the end of the file:

```gdscript
func _build_default_resource_registry():
	var rreg = ResourceRegistry.new()
	var project = ProjectTools.new()
	rreg.register("godot://project/info", "project_info",
		"Project metadata and settings.", "application/json",
		Callable(project, "get_project_info"))
	rreg.set_meta("_project", project)
	return rreg
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_mcp_handler.gd`
Expected: PASS — all handler tests pass (the original 9 plus the 5 new), exit 0.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/mcp_handler.gd addons/godot_mcp/tests/test_mcp_handler.gd
git commit -m "feat: wire project tools and resource layer into mcp_handler"
```

---

## Task 6: Full suite + docs

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the full suite**

Run: `./addons/godot_mcp/run_tests.sh`
Expected: every suite reports `0 failed`, script exits 0.

- [ ] **Step 2: Update README tool count**

In `README.md`, the v1 scope section currently reads `## v1 scope (lean editor core, ~18 tools)` and lists tool groups. Add a Project/resources bullet under the Files/scripts bullet:

```markdown
- **Project:** `get_project_settings`, `list_project_resources`, `get_project_info`,
  plus the `godot://project/info` MCP resource
```

- [ ] **Step 3: Update CLAUDE.md scope line**

In `CLAUDE.md`, the Scope section reads `v1 is the lean editor core (currently 6 file/script tools: ...)`. Replace with:

```markdown
v1 is the lean editor core (9 tools: `read_file`, `list_dir`, `search_project`, `create_script`, `edit_script`, `validate_script`, `get_project_settings`, `list_project_resources`, `get_project_info`), plus the MCP resource layer serving `godot://project/info`.
```

Also add a bullet to the "Conventions that matter" section:

```markdown
- **Resources:** MCP resources are served by `resource_registry.gd` (mirror of `tool_registry.gd`); register them in `mcp_handler._build_default_resource_registry()`. Resource handlers use the same `{ok, value/error}` contract as tools; the registry adapts the result into `{contents: [{uri, mimeType, text}]}`.
```

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document project tools and resource layer"
```

---

## Self-Review

**Spec coverage:**
- `get_project_settings` (key/prefix/author-set) → Task 3. ✓
- `list_project_resources` (.tres/.res/.tscn, type, path, traversal) → Task 4. ✓
- `get_project_info` + `godot://project/info` resource (shared logic) → Tasks 2 & 5. ✓
- MCP resource layer (`ResourceRegistry`, capability, list/read, unknown-uri error) → Tasks 1 & 5. ✓
- Headless testability → every task runs under the existing `test_case.gd` harness. ✓
- snake_case naming → used throughout. ✓
- Path safety via `validate()` → `list_project_resources` (Task 4). ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; all code shown in full. ✓

**Type consistency:** `ResourceRegistry` methods (`register`, `list_resources`, `has`, `read_resource`) are defined in Task 1 and called identically in Task 5. `ProjectTools` methods (`get_project_info`, `get_project_settings`, `list_project_resources`) defined in Tasks 2-4, registered with matching names in Task 5. Result contract `{ok, value/error}` consistent across all handlers and both registries. ✓

**Note for implementer:** `_author_settings()` uses `ConfigFile` against `res://project.godot` rather than `ProjectSettings.get_property_list()` — this yields *exactly* the author-set keys with no fragile is-default detection, and is fully deterministic headless.
```
