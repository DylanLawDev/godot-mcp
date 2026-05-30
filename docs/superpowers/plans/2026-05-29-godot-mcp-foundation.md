# Godot MCP Foundation + File/Script Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pure-GDScript Godot editor plugin that hosts an HTTP MCP server (Streamable HTTP, plain JSON responses) in-editor, exposing the 6 file/script tools (`read_file`, `list_dir`, `search_project`, `create_script`, `edit_script`, `validate_script`), so Claude Code can connect via `claude mcp add --transport http` and use them end-to-end.

**Architecture:** Pure logic (HTTP parsing, JSON-RPC, MCP protocol, tool execution) is split from IO/editor side effects so it is fully unit-testable headless. A `TCPServer`-based `HttpServer` exposes a single `poll()` method driven from the `EditorPlugin._process()` in-editor and from a busy-loop in tests. The MCP layer is stateless (no sessions): each POST to `/mcp` gets a single `application/json` JSON-RPC response. All editor/Godot APIs run on the editor main thread (no threading needed — execution serializes on `_process`).

**Tech Stack:** Godot 4.6.1 (GDScript, `@tool` scripts), `TCPServer`/`StreamPeerTCP` for HTTP/1.1, `FileAccess`/`DirAccess` for files, `GDScript.reload()` + a custom `Logger` for script validation. Tests use a homegrown headless runner (`extends SceneTree`, run via `godot4 --headless --path . --script ...`) — zero external dependencies.

**Conventions used throughout this plan:**
- `godot4` is the Godot 4.6.1 binary (on this machine: `/home/dylan/.local/bin/godot4`). If `godot4` is not on `PATH`, set `GODOT=/home/dylan/.local/bin/godot4` and substitute.
- Every addon **runtime** script starts with `@tool` (it must run inside the editor). Test scripts do **not** use `@tool`.
- All runtime classes are referenced via `const X = preload("res://...")` (no `class_name` globals).
- **Tool handler contract:** every tool is a `Callable` taking `args: Dictionary` and returning either `{"ok": true, "value": <Variant>}` or `{"ok": false, "error": <String>}`.
- **MCP result contract:** `tools/call` returns `{"content": [{"type": "text", "text": <String>}], "isError": <bool>}`.

---

## File Structure

```
project.godot                              # minimal project so res:// resolves & the addon can load
addons/godot_mcp/
  plugin.cfg                               # plugin manifest (entry = mcp_plugin.gd)
  mcp_plugin.gd                            # EditorPlugin: start/stop HttpServer, call poll() each _process
  http_server.gd                           # TCPServer wrapper: start/poll/stop, per-client buffering, HTTP framing
  http_message.gd                          # PURE: parse_request(), header_end(), content_length(), build_response()
  jsonrpc.gd                               # PURE: parse(), result(), error() JSON-RPC 2.0 envelopes
  mcp_handler.gd                           # MCP: handle_message(text) -> response text; initialize/ping/tools.*
  tool_registry.gd                         # register/list_tools/call_tool (wraps results into MCP content)
  utils/paths.gd                           # PURE: res:// normalize + in-project validation + ensure_extension
  tools/file_tools.gd                      # read_file, list_dir, search_project
  tools/script_tools.gd                    # create_script, edit_script, validate_script
  tests/
    test_case.gd                           # extends SceneTree: assert helpers, auto-discovery, exit code
    test_paths.gd
    test_http_message.gd
    test_jsonrpc.gd
    test_tool_registry.gd
    test_file_tools.gd
    test_script_tools.gd
    test_mcp_handler.gd
    test_http_server.gd
  run_tests.sh                             # runs every tests/test_*.gd headless; non-zero if any suite fails
docs/superpowers/plans/2026-05-29-godot-mcp-foundation.md   # this plan
```

**Responsibilities (one clear job each):**
- `http_message.gd` / `jsonrpc.gd` / `utils/paths.gd` — pure string/data transforms, no IO.
- `tool_registry.gd` — tool lookup + MCP content wrapping, no knowledge of HTTP or files.
- `tools/*.gd` — actual file/script operations, no knowledge of MCP/HTTP.
- `mcp_handler.gd` — MCP method routing; owns a `ToolRegistry`; no socket knowledge.
- `http_server.gd` — sockets + HTTP framing; delegates message handling to an injected `Callable`.
- `mcp_plugin.gd` — editor lifecycle wiring only.

---

## Task 1: Project scaffold + headless test harness

**Files:**
- Create: `project.godot`
- Create: `addons/godot_mcp/tests/test_case.gd`
- Create: `addons/godot_mcp/run_tests.sh`
- Create: `addons/godot_mcp/tests/test_harness_selfcheck.gd` (temporary; deleted in Step 6)

- [ ] **Step 1: Create the minimal Godot project file**

Create `project.godot` so `res://` resolves and the addon directory is part of a real project:

```ini
config_version=5

[application]

config/name="Godot MCP"
config/features=PackedStringArray("4.6")

[editor_plugins]

enabled=PackedStringArray()
```

(`enabled` stays empty until Task 13 — headless tests do not need the plugin enabled, only `res://` resolution.)

- [ ] **Step 2: Create the test base class**

Create `addons/godot_mcp/tests/test_case.gd`. It extends `SceneTree` so Godot runs it standalone via `--script`; `_init()` auto-discovers `test_*` methods, runs them, prints a summary, and `quit()`s with a non-zero code on any failure (so CI/`run_tests.sh` sees the failure).

```gdscript
extends SceneTree
# Base test case. A concrete test file does:
#   extends "res://addons/godot_mcp/tests/test_case.gd"
# and defines methods named test_*. Each is auto-run.
# Run a single suite:
#   godot4 --headless --path . --script addons/godot_mcp/tests/test_foo.gd
# Exit code is non-zero if any assertion failed.

var _passed := 0
var _failed := 0
var _cur := ""

func _init() -> void:
	for m in get_method_list():
		var n: String = m["name"]
		if n.begins_with("test_"):
			_cur = n
			call(n)
	print("=== %d passed, %d failed (%s) ===" % [_passed, _failed, _suite_name()])
	quit(1 if _failed > 0 else 0)

func _suite_name() -> String:
	return (get_script().resource_path as String).get_file()

func _fail(detail: String) -> void:
	_failed += 1
	printerr("  FAIL [%s] %s" % [_cur, detail])

func assert_true(cond: bool, msg := "") -> void:
	if cond: _passed += 1
	else: _fail("assert_true failed. " + msg)

func assert_false(cond: bool, msg := "") -> void:
	if not cond: _passed += 1
	else: _fail("assert_false failed. " + msg)

func assert_eq(actual, expected, msg := "") -> void:
	if actual == expected: _passed += 1
	else: _fail("assert_eq failed: expected %s but got %s. %s" % [str(expected), str(actual), msg])

func assert_ne(actual, unexpected, msg := "") -> void:
	if actual != unexpected: _passed += 1
	else: _fail("assert_ne failed: did not expect %s. %s" % [str(unexpected), msg])

func assert_has(haystack, needle, msg := "") -> void:
	if needle in haystack: _passed += 1
	else: _fail("assert_has failed: %s not in %s. %s" % [str(needle), str(haystack), msg])
```

- [ ] **Step 3: Write a temporary self-check suite**

Create `addons/godot_mcp/tests/test_harness_selfcheck.gd` to prove the harness reports both passes and failures:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

func test_pass_eq() -> void:
	assert_eq(2 + 2, 4)

func test_pass_true() -> void:
	assert_true("res://x".begins_with("res://"))

func test_intentional_fail() -> void:
	assert_eq(1, 2, "this failure is expected during Step 4")
```

- [ ] **Step 4: Run the self-check and verify it FAILS as expected**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_harness_selfcheck.gd; echo "EXIT=$?"`
Expected: prints `FAIL [test_intentional_fail] ...`, then `=== 2 passed, 1 failed (test_harness_selfcheck.gd) ===`, and `EXIT=1`.

- [ ] **Step 5: Create the aggregating test runner**

Create `addons/godot_mcp/run_tests.sh`:

```bash
#!/usr/bin/env bash
# Runs every addons/godot_mcp/tests/test_*.gd headless.
# Exits non-zero if any suite fails. Skips the test_case.gd base.
set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot4}"
fails=0
for t in "$PROJECT_ROOT"/addons/godot_mcp/tests/test_*.gd; do
	base="$(basename "$t")"
	[ "$base" = "test_case.gd" ] && continue
	rel="${t#"$PROJECT_ROOT"/}"
	echo ">>> $base"
	"$GODOT" --headless --path "$PROJECT_ROOT" --script "$rel" || fails=$((fails+1))
done
echo ">>> suites failed: $fails"
[ "$fails" -eq 0 ]
```

Make it executable: `chmod +x addons/godot_mcp/run_tests.sh`

- [ ] **Step 6: Run the runner, confirm it catches the failure, then delete the self-check**

Run: `./addons/godot_mcp/run_tests.sh; echo "RUNNER_EXIT=$?"`
Expected: ends with `>>> suites failed: 1` and `RUNNER_EXIT=1`.

Then remove the temporary suite:

```bash
rm addons/godot_mcp/tests/test_harness_selfcheck.gd
```

- [ ] **Step 7: Confirm an empty suite set passes, then commit**

Run: `./addons/godot_mcp/run_tests.sh; echo "RUNNER_EXIT=$?"`
Expected: no `test_*.gd` matched (or only `test_case.gd` skipped), `>>> suites failed: 0`, `RUNNER_EXIT=0`.

```bash
git add project.godot addons/godot_mcp/tests/test_case.gd addons/godot_mcp/run_tests.sh
git commit -m "feat: project scaffold and headless GDScript test harness"
```

---

## Task 2: Path utilities (`utils/paths.gd`)

Pure functions for normalizing user-supplied paths into safe `res://` paths and rejecting traversal outside the project. Used by every file/script tool.

**Files:**
- Create: `addons/godot_mcp/utils/paths.gd`
- Test: `addons/godot_mcp/tests/test_paths.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_paths.gd`:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

func test_normalize_adds_prefix() -> void:
	assert_eq(Paths.normalize("foo/bar.gd"), "res://foo/bar.gd")

func test_normalize_keeps_prefix() -> void:
	assert_eq(Paths.normalize("res://foo/bar.gd"), "res://foo/bar.gd")

func test_normalize_strips_leading_slash() -> void:
	assert_eq(Paths.normalize("/foo.gd"), "res://foo.gd")

func test_ensure_extension_adds_when_missing() -> void:
	assert_eq(Paths.ensure_extension("res://a/b", ".gd"), "res://a/b.gd")

func test_ensure_extension_keeps_when_present() -> void:
	assert_eq(Paths.ensure_extension("res://a/b.gd", ".gd"), "res://a/b.gd")

func test_validate_accepts_in_project() -> void:
	var r := Paths.validate("scripts/player.gd")
	assert_true(r["ok"], str(r))
	assert_eq(r["path"], "res://scripts/player.gd")

func test_validate_rejects_parent_traversal() -> void:
	var r := Paths.validate("res://../secret.txt")
	assert_false(r["ok"])
	assert_ne(r["error"], "")

func test_validate_rejects_embedded_traversal() -> void:
	var r := Paths.validate("scripts/../../etc/passwd")
	assert_false(r["ok"])
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_paths.gd; echo "EXIT=$?"`
Expected: FAIL — script load error because `utils/paths.gd` does not exist yet (non-zero exit).

- [ ] **Step 3: Write the implementation**

Create `addons/godot_mcp/utils/paths.gd`:

```gdscript
@tool
extends RefCounted

# Normalize an arbitrary path into a res:// path (no validation).
static func normalize(p: String) -> String:
	if p.begins_with("res://"):
		return p
	while p.begins_with("/"):
		p = p.substr(1)
	return "res://" + p

static func ensure_extension(p: String, ext: String) -> String:
	if p.ends_with(ext):
		return p
	return p + ext

# Normalize AND reject anything that escapes the project root.
# Returns {ok: bool, path: String, error: String}.
static func validate(p: String) -> Dictionary:
	if p.strip_edges() == "":
		return {"ok": false, "path": "", "error": "Path is empty"}
	var norm := normalize(p)
	# Reject parent-directory traversal anywhere in the path.
	var rest := norm.substr("res://".length())
	for segment in rest.split("/"):
		if segment == "..":
			return {"ok": false, "path": "", "error": "Path escapes project root: " + p}
	return {"ok": true, "path": norm, "error": ""}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_paths.gd; echo "EXIT=$?"`
Expected: `=== 8 passed, 0 failed (test_paths.gd) ===`, `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/utils/paths.gd addons/godot_mcp/tests/test_paths.gd
git commit -m "feat: res:// path normalization and traversal validation"
```

---

## Task 3: HTTP/1.1 message parsing & response building (`http_message.gd`)

Pure functions: turn a raw HTTP request string into a structured dict, detect when a full request has arrived (for the socket buffer loop), and build a raw HTTP response string.

**Files:**
- Create: `addons/godot_mcp/http_message.gd`
- Test: `addons/godot_mcp/tests/test_http_message.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_http_message.gd`:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const Http = preload("res://addons/godot_mcp/http_message.gd")

const REQ := "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"

func test_header_end_found() -> void:
	# Index just past the blank-line terminator.
	assert_eq(Http.header_end(REQ), REQ.find("\r\n\r\n") + 4)

func test_header_end_missing() -> void:
	assert_eq(Http.header_end("POST /mcp HTTP/1.1\r\nHost: x\r\n"), -1)

func test_parse_method_and_path() -> void:
	var r := Http.parse_request(REQ)
	assert_true(r["ok"], str(r))
	assert_eq(r["method"], "POST")
	assert_eq(r["path"], "/mcp")
	assert_eq(r["body"], "{}")

func test_parse_headers_lowercased() -> void:
	var r := Http.parse_request(REQ)
	assert_eq(r["headers"]["content-type"], "application/json")
	assert_eq(r["headers"]["content-length"], "2")

func test_content_length_reads_header() -> void:
	var r := Http.parse_request(REQ)
	assert_eq(Http.content_length(r["headers"]), 2)

func test_content_length_defaults_zero() -> void:
	assert_eq(Http.content_length({}), 0)

func test_parse_bad_request_line() -> void:
	var r := Http.parse_request("garbage-without-spaces\r\n\r\n")
	assert_false(r["ok"])

func test_build_response_has_status_and_length() -> void:
	var out := Http.build_response(200, "{\"a\":1}")
	assert_true(out.begins_with("HTTP/1.1 200 OK\r\n"))
	assert_has(out, "Content-Type: application/json\r\n")
	# Content-Length must be the UTF-8 byte length of the body.
	assert_has(out, "Content-Length: 7\r\n")
	assert_true(out.ends_with("\r\n\r\n{\"a\":1}"))

func test_build_response_status_text() -> void:
	assert_true(Http.build_response(405, "no").begins_with("HTTP/1.1 405 Method Not Allowed\r\n"))
	assert_true(Http.build_response(202, "").begins_with("HTTP/1.1 202 Accepted\r\n"))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_http_message.gd; echo "EXIT=$?"`
Expected: FAIL — `http_message.gd` does not exist (non-zero exit).

- [ ] **Step 3: Write the implementation**

Create `addons/godot_mcp/http_message.gd`:

```gdscript
@tool
extends RefCounted

const _STATUS := {
	200: "OK",
	202: "Accepted",
	400: "Bad Request",
	404: "Not Found",
	405: "Method Not Allowed",
	500: "Internal Server Error",
}

# Index of the first byte AFTER the "\r\n\r\n" header terminator, or -1 if not present yet.
static func header_end(raw: String) -> int:
	var idx := raw.find("\r\n\r\n")
	if idx == -1:
		return -1
	return idx + 4

# Parse a COMPLETE raw HTTP request. Returns
# {ok, method, path, version, headers (lowercased keys), body, error}.
static func parse_request(raw: String) -> Dictionary:
	var split := header_end(raw)
	var head := raw if split == -1 else raw.substr(0, split - 4)
	var body := "" if split == -1 else raw.substr(split)
	var lines := head.split("\r\n")
	if lines.size() == 0:
		return _bad("Empty request")
	var request_line: String = lines[0]
	var parts := request_line.split(" ", false)
	if parts.size() < 3:
		return _bad("Malformed request line: " + request_line)
	var headers := {}
	for i in range(1, lines.size()):
		var line: String = lines[i]
		var colon := line.find(":")
		if colon == -1:
			continue
		var key := line.substr(0, colon).strip_edges().to_lower()
		var value := line.substr(colon + 1).strip_edges()
		headers[key] = value
	return {
		"ok": true,
		"method": parts[0],
		"path": parts[1],
		"version": parts[2],
		"headers": headers,
		"body": body,
		"error": "",
	}

static func content_length(headers: Dictionary) -> int:
	if headers.has("content-length"):
		return int(headers["content-length"])
	return 0

static func build_response(status: int, body: String, content_type := "application/json", extra_headers := {}) -> String:
	var reason: String = _STATUS.get(status, "OK")
	var byte_len := body.to_utf8_buffer().size()
	var out := "HTTP/1.1 %d %s\r\n" % [status, reason]
	out += "Content-Type: %s\r\n" % content_type
	out += "Content-Length: %d\r\n" % byte_len
	out += "Connection: close\r\n"
	for k in extra_headers:
		out += "%s: %s\r\n" % [k, extra_headers[k]]
	out += "\r\n"
	out += body
	return out

static func _bad(msg: String) -> Dictionary:
	return {"ok": false, "method": "", "path": "", "version": "", "headers": {}, "body": "", "error": msg}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_http_message.gd; echo "EXIT=$?"`
Expected: `=== 10 passed, 0 failed (test_http_message.gd) ===`, `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/http_message.gd addons/godot_mcp/tests/test_http_message.gd
git commit -m "feat: HTTP/1.1 request parsing and response building"
```

---

## Task 4: JSON-RPC 2.0 envelopes (`jsonrpc.gd`)

Pure functions to parse a JSON-RPC request string and build result/error envelopes.

**Files:**
- Create: `addons/godot_mcp/jsonrpc.gd`
- Test: `addons/godot_mcp/tests/test_jsonrpc.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_jsonrpc.gd`:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const JsonRpc = preload("res://addons/godot_mcp/jsonrpc.gd")

func test_parse_request_with_id() -> void:
	var r := JsonRpc.parse('{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}')
	assert_true(r["ok"], str(r))
	assert_eq(r["id"], 7)
	assert_eq(r["method"], "tools/list")
	assert_false(r["is_notification"])

func test_parse_notification_has_no_id() -> void:
	var r := JsonRpc.parse('{"jsonrpc":"2.0","method":"notifications/initialized"}')
	assert_true(r["ok"], str(r))
	assert_true(r["is_notification"])

func test_parse_params_default_empty_dict() -> void:
	var r := JsonRpc.parse('{"jsonrpc":"2.0","id":1,"method":"ping"}')
	assert_eq(r["params"], {})

func test_parse_invalid_json() -> void:
	var r := JsonRpc.parse("{not json")
	assert_false(r["ok"])

func test_parse_non_object() -> void:
	var r := JsonRpc.parse("[1,2,3]")
	assert_false(r["ok"])

func test_result_envelope() -> void:
	var env := JsonRpc.result(5, {"a": 1})
	assert_eq(env["jsonrpc"], "2.0")
	assert_eq(env["id"], 5)
	assert_eq(env["result"], {"a": 1})

func test_error_envelope() -> void:
	var env := JsonRpc.error(null, -32601, "Method not found")
	assert_eq(env["jsonrpc"], "2.0")
	assert_eq(env["id"], null)
	assert_eq(env["error"]["code"], -32601)
	assert_eq(env["error"]["message"], "Method not found")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_jsonrpc.gd; echo "EXIT=$?"`
Expected: FAIL — `jsonrpc.gd` does not exist (non-zero exit).

- [ ] **Step 3: Write the implementation**

Create `addons/godot_mcp/jsonrpc.gd`:

```gdscript
@tool
extends RefCounted

# Parse a single JSON-RPC 2.0 message. Returns
# {ok, id, method, params, is_notification}. A request without "id" is a notification.
static func parse(text: String) -> Dictionary:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "id": null, "method": "", "params": {}, "is_notification": false}
	var id = data.get("id", null)
	var has_id := data.has("id")
	var params = data.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}
	return {
		"ok": true,
		"id": id,
		"method": data.get("method", ""),
		"params": params,
		"is_notification": not has_id,
	}

static func result(id, result_value) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result_value}

static func error(id, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_jsonrpc.gd; echo "EXIT=$?"`
Expected: `=== 7 passed, 0 failed (test_jsonrpc.gd) ===`, `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/jsonrpc.gd addons/godot_mcp/tests/test_jsonrpc.gd
git commit -m "feat: JSON-RPC 2.0 parse and envelope helpers"
```

---

## Task 5: Tool registry (`tool_registry.gd`)

Holds registered tools, lists their MCP schemas, and routes `tools/call` — wrapping each tool's `{ok,value}`/`{ok,error}` return into the MCP `{content, isError}` shape.

**Files:**
- Create: `addons/godot_mcp/tool_registry.gd`
- Test: `addons/godot_mcp/tests/test_tool_registry.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_tool_registry.gd`. The fake tools are defined as methods on the test (a `SceneTree`) and registered as `Callable`s:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const ToolRegistry = preload("res://addons/godot_mcp/tool_registry.gd")

func _echo_tool(args: Dictionary) -> Dictionary:
	return {"ok": true, "value": {"echoed": args.get("msg", "")}}

func _string_tool(_args: Dictionary) -> Dictionary:
	return {"ok": true, "value": "plain text"}

func _failing_tool(_args: Dictionary) -> Dictionary:
	return {"ok": false, "error": "boom"}

func _make_registry() -> RefCounted:
	var reg = ToolRegistry.new()
	reg.register("echo", "Echo the input", {"type": "object"}, Callable(self, "_echo_tool"))
	reg.register("stringy", "Returns a string", {"type": "object"}, Callable(self, "_string_tool"))
	reg.register("boom", "Always fails", {"type": "object"}, Callable(self, "_failing_tool"))
	return reg

func test_list_tools_exposes_schema() -> void:
	var tools = _make_registry().list_tools()
	assert_eq(tools.size(), 3)
	assert_eq(tools[0]["name"], "echo")
	assert_eq(tools[0]["description"], "Echo the input")
	assert_eq(tools[0]["inputSchema"], {"type": "object"})

func test_call_tool_wraps_dict_value_as_json_text() -> void:
	var res = _make_registry().call_tool("echo", {"msg": "hi"})
	assert_false(res["isError"])
	assert_eq(res["content"][0]["type"], "text")
	assert_eq(res["content"][0]["text"], '{"echoed":"hi"}')

func test_call_tool_passes_string_value_through() -> void:
	var res = _make_registry().call_tool("stringy", {})
	assert_eq(res["content"][0]["text"], "plain text")
	assert_false(res["isError"])

func test_call_tool_error_sets_is_error() -> void:
	var res = _make_registry().call_tool("boom", {})
	assert_true(res["isError"])
	assert_eq(res["content"][0]["text"], "boom")

func test_call_unknown_tool() -> void:
	var res = _make_registry().call_tool("nope", {})
	assert_true(res["isError"])
	assert_has(res["content"][0]["text"], "Unknown tool")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_tool_registry.gd; echo "EXIT=$?"`
Expected: FAIL — `tool_registry.gd` does not exist (non-zero exit).

- [ ] **Step 3: Write the implementation**

Create `addons/godot_mcp/tool_registry.gd`:

```gdscript
@tool
extends RefCounted

var _tools: Array = []  # each: {name, description, inputSchema, handler: Callable}

func register(name: String, description: String, input_schema: Dictionary, handler: Callable) -> void:
	_tools.append({
		"name": name,
		"description": description,
		"inputSchema": input_schema,
		"handler": handler,
	})

# Schemas only — the shape MCP tools/list expects.
func list_tools() -> Array:
	var out := []
	for t in _tools:
		out.append({
			"name": t["name"],
			"description": t["description"],
			"inputSchema": t["inputSchema"],
		})
	return out

# Returns the MCP tools/call result: {content: [{type:"text", text}], isError}.
func call_tool(name: String, args: Dictionary) -> Dictionary:
	for t in _tools:
		if t["name"] == name:
			var r: Dictionary = t["handler"].call(args)
			if r.get("ok", false):
				var val = r.get("value")
				var text: String = val if typeof(val) == TYPE_STRING else JSON.stringify(val)
				return {"content": [{"type": "text", "text": text}], "isError": false}
			return {"content": [{"type": "text", "text": str(r.get("error", "unknown error"))}], "isError": true}
	return {"content": [{"type": "text", "text": "Unknown tool: " + name}], "isError": true}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_tool_registry.gd; echo "EXIT=$?"`
Expected: `=== 5 passed, 0 failed (test_tool_registry.gd) ===`, `EXIT=0`.

(Note: `JSON.stringify` on `{"echoed":"hi"}` produces `{"echoed":"hi"}` with no spaces — that is why the expected text has no spaces.)

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/tool_registry.gd addons/godot_mcp/tests/test_tool_registry.gd
git commit -m "feat: tool registry with MCP content wrapping"
```

---

## Task 6: File tools — `read_file`, `list_dir`, `search_project` (`tools/file_tools.gd`)

The three read-oriented tools. Each is a method matching the tool-handler contract `(args) -> {ok,value}|{ok,error}`. All use `FileAccess`/`DirAccess`, which work headless without an editor.

**Files:**
- Create: `addons/godot_mcp/tools/file_tools.gd`
- Test: `addons/godot_mcp/tests/test_file_tools.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_file_tools.gd`. It builds a temporary directory tree under `res://` (the project root, since we run with `--path .`) and cleans it up:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const FileTools = preload("res://addons/godot_mcp/tools/file_tools.gd")

const SANDBOX := "res://_filetools_test"

func _setup() -> void:
	_teardown()
	DirAccess.make_dir_recursive_absolute(SANDBOX + "/sub")
	_write(SANDBOX + "/a.txt", "hello world")
	_write(SANDBOX + "/needle.gd", "func find_me():\n\tpass\n")
	_write(SANDBOX + "/sub/b.txt", "another find_me here")

func _teardown() -> void:
	if DirAccess.dir_exists_absolute(SANDBOX):
		_rm_recursive(SANDBOX)

func _write(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f = null

func _rm_recursive(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var child := path + "/" + name
		if d.current_is_dir():
			_rm_recursive(child)
		else:
			DirAccess.remove_absolute(child)
		name = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)

func test_read_file_returns_content() -> void:
	_setup()
	var ft = FileTools.new()
	var r = ft.read_file({"path": "_filetools_test/a.txt"})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"], "hello world")
	_teardown()

func test_read_file_missing() -> void:
	_setup()
	var r = FileTools.new().read_file({"path": "_filetools_test/nope.txt"})
	assert_false(r["ok"])
	assert_has(r["error"], "not found")
	_teardown()

func test_read_file_rejects_traversal() -> void:
	var r = FileTools.new().read_file({"path": "../../etc/passwd"})
	assert_false(r["ok"])

func test_list_dir_lists_entries() -> void:
	_setup()
	var r = FileTools.new().list_dir({"path": "_filetools_test"})
	assert_true(r["ok"], str(r))
	var names := []
	for e in r["value"]:
		names.append(e["name"])
	assert_has(names, "a.txt")
	assert_has(names, "needle.gd")
	assert_has(names, "sub")
	# "sub" must be flagged as a directory.
	for e in r["value"]:
		if e["name"] == "sub":
			assert_true(e["is_dir"])
	_teardown()

func test_list_dir_missing() -> void:
	var r = FileTools.new().list_dir({"path": "_filetools_test/does_not_exist"})
	assert_false(r["ok"])

func test_search_project_finds_matches_recursively() -> void:
	_setup()
	var r = FileTools.new().search_project({"query": "find_me", "path": "_filetools_test"})
	assert_true(r["ok"], str(r))
	# Two files contain "find_me": needle.gd and sub/b.txt.
	var files := {}
	for m in r["value"]:
		files[m["file"]] = true
		assert_has(m["text"], "find_me")
		assert_true(m["line"] >= 1)
	assert_eq(files.size(), 2)
	_teardown()

func test_search_project_no_matches() -> void:
	_setup()
	var r = FileTools.new().search_project({"query": "zzz_nothing", "path": "_filetools_test"})
	assert_true(r["ok"])
	assert_eq(r["value"].size(), 0)
	_teardown()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_file_tools.gd; echo "EXIT=$?"`
Expected: FAIL — `tools/file_tools.gd` does not exist (non-zero exit).

- [ ] **Step 3: Write the implementation**

Create `addons/godot_mcp/tools/file_tools.gd`:

```gdscript
@tool
extends RefCounted

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

const _MAX_RESULTS := 200          # cap search hits
const _MAX_FILE_BYTES := 1_000_000 # skip files larger than ~1MB during search

func read_file(args: Dictionary) -> Dictionary:
	var v := Paths.validate(str(args.get("path", "")))
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var path: String = v["path"]
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: " + path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Cannot open file: " + path}
	var content := f.get_as_text()
	f = null
	return {"ok": true, "value": content}

func list_dir(args: Dictionary) -> Dictionary:
	var v := Paths.validate(str(args.get("path", "")))
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var path: String = v["path"]
	var d := DirAccess.open(path)
	if d == null:
		return {"ok": false, "error": "Directory not found: " + path}
	var entries := []
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		entries.append({
			"name": name,
			"path": path.path_join(name),
			"is_dir": d.current_is_dir(),
		})
		name = d.get_next()
	d.list_dir_end()
	return {"ok": true, "value": entries}

func search_project(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", ""))
	if query == "":
		return {"ok": false, "error": "query is required"}
	var root := str(args.get("path", "res://"))
	var v := Paths.validate(root)
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var matches := []
	_search_dir(v["path"], query, matches)
	return {"ok": true, "value": matches}

func _search_dir(dir_path: String, query: String, matches: Array) -> void:
	if matches.size() >= _MAX_RESULTS:
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var child := dir_path.path_join(name)
		if d.current_is_dir():
			_search_dir(child, query, matches)
		else:
			_search_file(child, query, matches)
		if matches.size() >= _MAX_RESULTS:
			break
		name = d.get_next()
	d.list_dir_end()

func _search_file(file_path: String, query: String, matches: Array) -> void:
	if not FileAccess.file_exists(file_path):
		return
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return
	if f.get_length() > _MAX_FILE_BYTES:
		f = null
		return
	var line_no := 0
	while not f.eof_reached():
		var line := f.get_line()
		line_no += 1
		if line.find(query) != -1:
			matches.append({"file": file_path, "line": line_no, "text": line})
			if matches.size() >= _MAX_RESULTS:
				break
	f = null
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_file_tools.gd; echo "EXIT=$?"`
Expected: `=== 7 passed, 0 failed (test_file_tools.gd) ===`, `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/tools/file_tools.gd addons/godot_mcp/tests/test_file_tools.gd
git commit -m "feat: read_file, list_dir, search_project tools"
```

---

## Task 7: Script tools — `create_script`, `edit_script`, `validate_script` (`tools/script_tools.gd`)

`create_script` writes a new `.gd` (creating parent dirs), `edit_script` overwrites an existing one, `validate_script` compiles GDScript source via `GDScript.reload()` and captures parse errors (message + line) using a custom `Logger`. All work headless; the editor filesystem rescan in `create_script` is guarded so it only runs when the plugin is live in an editor.

**Files:**
- Create: `addons/godot_mcp/tools/script_tools.gd`
- Test: `addons/godot_mcp/tests/test_script_tools.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_script_tools.gd`:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const ScriptTools = preload("res://addons/godot_mcp/tools/script_tools.gd")

const SANDBOX := "res://_scripttools_test"

func _teardown() -> void:
	if DirAccess.dir_exists_absolute(SANDBOX):
		var d := DirAccess.open(SANDBOX)
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if not d.current_is_dir():
				DirAccess.remove_absolute(SANDBOX + "/" + name)
			name = d.get_next()
		d.list_dir_end()
		DirAccess.remove_absolute(SANDBOX)

func test_create_script_writes_file_and_dirs() -> void:
	_teardown()
	var st = ScriptTools.new()
	var r = st.create_script({"path": "_scripttools_test/player.gd", "content": "extends Node\n"})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"]["path"], "res://_scripttools_test/player.gd")
	assert_true(FileAccess.file_exists("res://_scripttools_test/player.gd"))
	assert_eq(FileAccess.open("res://_scripttools_test/player.gd", FileAccess.READ).get_as_text(), "extends Node\n")
	_teardown()

func test_create_script_adds_gd_extension() -> void:
	_teardown()
	var r = ScriptTools.new().create_script({"path": "_scripttools_test/foo", "content": "extends Node\n"})
	assert_true(r["ok"], str(r))
	assert_eq(r["value"]["path"], "res://_scripttools_test/foo.gd")
	_teardown()

func test_edit_script_requires_existing_file() -> void:
	_teardown()
	var r = ScriptTools.new().edit_script({"path": "_scripttools_test/missing.gd", "content": "x"})
	assert_false(r["ok"])
	assert_has(r["error"], "not found")
	_teardown()

func test_edit_script_overwrites() -> void:
	_teardown()
	var st = ScriptTools.new()
	st.create_script({"path": "_scripttools_test/e.gd", "content": "extends Node\n"})
	var r = st.edit_script({"path": "_scripttools_test/e.gd", "content": "extends Node2D\n"})
	assert_true(r["ok"], str(r))
	assert_eq(FileAccess.open("res://_scripttools_test/e.gd", FileAccess.READ).get_as_text(), "extends Node2D\n")
	_teardown()

func test_validate_script_accepts_valid_source() -> void:
	var r = ScriptTools.new().validate_script({"content": "extends Node\nfunc _ready():\n\tprint(1)\n"})
	assert_true(r["ok"], str(r))
	assert_true(r["value"]["valid"])
	assert_eq(r["value"]["errors"].size(), 0)

func test_validate_script_reports_parse_error_with_line() -> void:
	# Missing ':' after func signature is a parse error.
	var r = ScriptTools.new().validate_script({"content": "extends Node\nfunc bad(\n\tpass\n"})
	assert_true(r["ok"], str(r))
	assert_false(r["value"]["valid"])
	assert_true(r["value"]["errors"].size() >= 1)
	assert_true(r["value"]["errors"][0]["line"] >= 1)
	assert_ne(r["value"]["errors"][0]["message"], "")

func test_validate_script_from_file() -> void:
	_teardown()
	var st = ScriptTools.new()
	st.create_script({"path": "_scripttools_test/v.gd", "content": "extends Node\n"})
	var r = st.validate_script({"path": "_scripttools_test/v.gd"})
	assert_true(r["ok"], str(r))
	assert_true(r["value"]["valid"])
	_teardown()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_script_tools.gd; echo "EXIT=$?"`
Expected: FAIL — `tools/script_tools.gd` does not exist (non-zero exit).

- [ ] **Step 3: Write the implementation**

Create `addons/godot_mcp/tools/script_tools.gd`. The `_CaptureLogger` inner class subclasses Godot's `Logger` to capture parse error message + line (verified: `reload()` returns `ERR_PARSE_ERROR` (43) on failure and `OK` (0) on success; the human-readable message arrives in the logger's `code` argument and the source line in `line`):

```gdscript
@tool
extends RefCounted

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

# Captures engine error output (incl. GDScript parse errors) during a reload() window.
class _CaptureLogger extends Logger:
	var errors: Array = []
	func _log_error(_function, _file, line, code, _rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		errors.append({"line": line, "message": code})
	func _log_message(_message, _error) -> void:
		pass

func create_script(args: Dictionary) -> Dictionary:
	var v := Paths.validate(str(args.get("path", "")))
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var path := Paths.ensure_extension(v["path"], ".gd")
	var content := str(args.get("content", ""))
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			return {"ok": false, "error": "Failed to create directory %s (error %d)" % [dir, err]}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Failed to create file: " + path}
	f.store_string(content)
	f = null
	_rescan_filesystem()
	return {"ok": true, "value": {"path": path}}

func edit_script(args: Dictionary) -> Dictionary:
	var v := Paths.validate(str(args.get("path", "")))
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	var path: String = v["path"]
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "Script not found: " + path}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Failed to open for writing: " + path}
	f.store_string(str(args.get("content", "")))
	f = null
	_rescan_filesystem()
	return {"ok": true, "value": {"path": path}}

func validate_script(args: Dictionary) -> Dictionary:
	var src := str(args.get("content", ""))
	if src == "" and args.has("path"):
		var v := Paths.validate(str(args.get("path", "")))
		if not v["ok"]:
			return {"ok": false, "error": v["error"]}
		if not FileAccess.file_exists(v["path"]):
			return {"ok": false, "error": "Script not found: " + v["path"]}
		src = FileAccess.open(v["path"], FileAccess.READ).get_as_text()
	var cap := _CaptureLogger.new()
	OS.add_logger(cap)
	var gd := GDScript.new()
	gd.source_code = src
	var err := gd.reload()
	OS.remove_logger(cap)
	return {"ok": true, "value": {"valid": err == OK, "errors": cap.errors}}

# Only meaningful inside a live editor; the plugin registers itself in Engine metadata (Task 13).
func _rescan_filesystem() -> void:
	if not Engine.has_meta("GodotMCPPlugin"):
		return
	var plugin = Engine.get_meta("GodotMCPPlugin")
	var ei = plugin.get_editor_interface()
	ei.get_resource_filesystem().scan()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_script_tools.gd; echo "EXIT=$?"`
Expected: `=== 7 passed, 0 failed (test_script_tools.gd) ===`, `EXIT=0`.

Note: the broken-source `reload()` will print a `SCRIPT ERROR: Parse Error: ...` line to stderr during `test_validate_script_reports_parse_error_with_line` — that is expected (it is the error being captured), not a test failure. The suite summary line is authoritative.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_mcp/tools/script_tools.gd addons/godot_mcp/tests/test_script_tools.gd
git commit -m "feat: create_script, edit_script, validate_script tools"
```

---

## Task 8: MCP protocol handler (`mcp_handler.gd`)

Routes JSON-RPC methods to MCP responses: `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`. Owns a fully-wired `ToolRegistry` (built from `file_tools` + `script_tools`), but accepts an injected registry for testing. Exposes a single seam, `handle_message(text) -> String`, returning the serialized JSON-RPC response, or `""` for notifications.

**Files:**
- Create: `addons/godot_mcp/mcp_handler.gd`
- Test: `addons/godot_mcp/tests/test_mcp_handler.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_mcp_handler.gd`. These tests use the **real** default registry (the file/script tools are headless-safe), plus a sandbox file for the `tools/call` round-trip:

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const McpHandler = preload("res://addons/godot_mcp/mcp_handler.gd")

func _parse(text: String) -> Dictionary:
	return JSON.parse_string(text)

func test_initialize_returns_server_info_and_capabilities() -> void:
	var h = McpHandler.new()
	var out := h.handle_message('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}')
	var d := _parse(out)
	assert_eq(d["id"], 1)
	assert_eq(d["result"]["protocolVersion"], "2025-06-18")
	assert_true(d["result"]["capabilities"].has("tools"))
	assert_eq(d["result"]["serverInfo"]["name"], "godot-mcp")

func test_initialize_defaults_protocol_version_when_absent() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}'))
	assert_eq(d["result"]["protocolVersion"], McpHandler.PROTOCOL_VERSION)

func test_notification_initialized_returns_empty_string() -> void:
	var h = McpHandler.new()
	assert_eq(h.handle_message('{"jsonrpc":"2.0","method":"notifications/initialized"}'), "")

func test_ping_returns_empty_result_object() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":3,"method":"ping"}'))
	assert_eq(d["result"], {})

func test_tools_list_includes_all_six_tools() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}'))
	var names := []
	for t in d["result"]["tools"]:
		names.append(t["name"])
	for expected in ["read_file", "list_dir", "search_project", "create_script", "edit_script", "validate_script"]:
		assert_has(names, expected)

func test_tools_call_read_file_round_trip() -> void:
	var f := FileAccess.open("res://_mcp_handler_test.txt", FileAccess.WRITE)
	f.store_string("payload")
	f = null
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"_mcp_handler_test.txt"}}}'))
	assert_false(d["result"]["isError"])
	assert_eq(d["result"]["content"][0]["text"], "payload")
	DirAccess.remove_absolute("res://_mcp_handler_test.txt")

func test_unknown_method_returns_error() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message('{"jsonrpc":"2.0","id":6,"method":"does/not/exist","params":{}}'))
	assert_eq(d["error"]["code"], -32601)

func test_invalid_json_returns_parse_error() -> void:
	var h = McpHandler.new()
	var d := _parse(h.handle_message("{not json"))
	assert_eq(d["error"]["code"], -32700)
	assert_eq(d["id"], null)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_mcp_handler.gd; echo "EXIT=$?"`
Expected: FAIL — `mcp_handler.gd` does not exist (non-zero exit).

- [ ] **Step 3: Write the implementation**

Create `addons/godot_mcp/mcp_handler.gd`:

```gdscript
@tool
extends RefCounted

const JsonRpc = preload("res://addons/godot_mcp/jsonrpc.gd")
const ToolRegistry = preload("res://addons/godot_mcp/tool_registry.gd")
const FileTools = preload("res://addons/godot_mcp/tools/file_tools.gd")
const ScriptTools = preload("res://addons/godot_mcp/tools/script_tools.gd")

const PROTOCOL_VERSION := "2025-06-18"
const SERVER_NAME := "godot-mcp"
const SERVER_VERSION := "0.1.0"

var _registry

func _init(registry = null) -> void:
	_registry = registry if registry != null else _build_default_registry()

# Single seam for the HTTP server AND tests.
# Returns the serialized JSON-RPC response, or "" for notifications (server replies 202, no body).
func handle_message(text: String) -> String:
	var req := JsonRpc.parse(text)
	if not req["ok"]:
		return JSON.stringify(JsonRpc.error(null, -32700, "Parse error"))
	var resp = _handle(req)
	if resp == null:
		return ""
	return JSON.stringify(resp)

func _handle(req: Dictionary):
	var method: String = req["method"]
	var id = req["id"]
	match method:
		"initialize":
			var pv = req["params"].get("protocolVersion", PROTOCOL_VERSION)
			if typeof(pv) != TYPE_STRING:
				pv = PROTOCOL_VERSION
			return JsonRpc.result(id, {
				"protocolVersion": pv,
				"capabilities": {"tools": {}},
				"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
			})
		"notifications/initialized":
			return null
		"ping":
			return JsonRpc.result(id, {})
		"tools/list":
			return JsonRpc.result(id, {"tools": _registry.list_tools()})
		"tools/call":
			var p: Dictionary = req["params"]
			return JsonRpc.result(id, _registry.call_tool(str(p.get("name", "")), p.get("arguments", {})))
		_:
			if req["is_notification"]:
				return null
			return JsonRpc.error(id, -32601, "Method not found: " + method)

func _build_default_registry():
	var reg = ToolRegistry.new()
	var files = FileTools.new()
	var scripts = ScriptTools.new()
	reg.register("read_file", "Read a UTF-8 text file from the project. Args: {path}.",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(files, "read_file"))
	reg.register("list_dir", "List entries of a project directory. Args: {path}.",
		{"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
		Callable(files, "list_dir"))
	reg.register("search_project", "Search project files for a substring. Args: {query, path?}.",
		{"type": "object", "properties": {"query": {"type": "string"}, "path": {"type": "string"}}, "required": ["query"]},
		Callable(files, "search_project"))
	reg.register("create_script", "Create a new .gd script (makes parent dirs). Args: {path, content}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
		Callable(scripts, "create_script"))
	reg.register("edit_script", "Overwrite an existing script's contents. Args: {path, content}.",
		{"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
		Callable(scripts, "edit_script"))
	reg.register("validate_script", "Validate GDScript syntax. Args: {content} or {path}.",
		{"type": "object", "properties": {"content": {"type": "string"}, "path": {"type": "string"}}},
		Callable(scripts, "validate_script"))
	# Keep tool instances alive for the lifetime of the registry by stashing them.
	reg.set_meta("_files", files)
	reg.set_meta("_scripts", scripts)
	return reg
```

Note on the `set_meta` calls: `FileTools`/`ScriptTools` are `RefCounted`. The `Callable`s hold references to them, so they stay alive as long as the registry's tool array does — the `set_meta` is belt-and-suspenders to make the ownership explicit and survive any future refactor of the registry's internal storage.

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_mcp_handler.gd; echo "EXIT=$?"`
Expected: `=== 8 passed, 0 failed (test_mcp_handler.gd) ===`, `EXIT=0`.

- [ ] **Step 5: Run the full suite to confirm no regressions, then commit**

Run: `./addons/godot_mcp/run_tests.sh; echo "RUNNER_EXIT=$?"`
Expected: every suite prints `0 failed`, ends with `>>> suites failed: 0`, `RUNNER_EXIT=0`.

```bash
git add addons/godot_mcp/mcp_handler.gd addons/godot_mcp/tests/test_mcp_handler.gd
git commit -m "feat: MCP protocol handler (initialize, ping, tools/list, tools/call)"
```

---

## Task 9: HTTP server (`http_server.gd`)

A `TCPServer` wrapper with `start(port)`, `poll()`, `stop()`. `poll()` accepts new connections, buffers incoming bytes per client, and once a full HTTP request has arrived, delegates the body to an injected `Callable` (in production: `McpHandler.handle_message`), frames the result as an HTTP response, sends it, and closes the connection. `poll()` is driven from the editor's `_process` (Task 13) and from a busy-loop in tests (verified working on loopback headless).

**Files:**
- Create: `addons/godot_mcp/http_server.gd`
- Test: `addons/godot_mcp/tests/test_http_server.gd`

- [ ] **Step 1: Write the failing test**

Create `addons/godot_mcp/tests/test_http_server.gd`. It starts the server on an OS-assigned port, connects a real loopback `StreamPeerTCP` client, and drives both sides with a bounded busy loop (the pattern was verified end-to-end against Godot 4.6.1):

```gdscript
extends "res://addons/godot_mcp/tests/test_case.gd"

const HttpServer = preload("res://addons/godot_mcp/http_server.gd")

# Test dispatch: echoes a fixed JSON-RPC result for "ok" bodies; returns "" (notification) for "notify".
func _dispatch(body: String) -> String:
	if body == "notify":
		return ""
	return '{"jsonrpc":"2.0","id":1,"result":{"echo":%s}}' % JSON.stringify(body)

# Sends one raw HTTP request to the running server and returns the full raw HTTP response.
func _round_trip(port: int, raw_request: String) -> String:
	var client := StreamPeerTCP.new()
	assert_true(client.connect_to_host("127.0.0.1", port) == OK)
	var server: Variant = _server
	var got := ""
	var sent := false
	for i in range(400):
		server.poll()
		client.poll()
		if not sent and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			client.put_data(raw_request.to_utf8_buffer())
			sent = true
		var avail := client.get_available_bytes()
		if avail > 0:
			var chunk: Array = client.get_data(avail)
			got += PackedByteArray(chunk[1]).get_string_from_utf8()
			if got.find("\r\n\r\n") != -1:
				break
		OS.delay_msec(2)
	return got

var _server

func test_post_mcp_dispatches_and_responds_200() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch"))
	assert_eq(_server.start(0), OK)
	var port: int = _server.get_port()
	var body := "ok"
	var req := "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s" % [body.length(), body]
	var resp := _round_trip(port, req)
	assert_has(resp, "HTTP/1.1 200 OK")
	assert_has(resp, "application/json")
	assert_has(resp, '"echo"')
	_server.stop()

func test_notification_responds_202_empty() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch"))
	assert_eq(_server.start(0), OK)
	var port: int = _server.get_port()
	var body := "notify"
	var req := "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s" % [body.length(), body]
	var resp := _round_trip(port, req)
	assert_has(resp, "HTTP/1.1 202 Accepted")
	_server.stop()

func test_get_returns_405() -> void:
	_server = HttpServer.new(Callable(self, "_dispatch"))
	assert_eq(_server.start(0), OK)
	var port: int = _server.get_port()
	var req := "GET /mcp HTTP/1.1\r\nHost: x\r\n\r\n"
	var resp := _round_trip(port, req)
	assert_has(resp, "HTTP/1.1 405 Method Not Allowed")
	_server.stop()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_http_server.gd; echo "EXIT=$?"`
Expected: FAIL — `http_server.gd` does not exist (non-zero exit).

- [ ] **Step 3: Write the implementation**

Create `addons/godot_mcp/http_server.gd`:

```gdscript
@tool
extends RefCounted

const Http = preload("res://addons/godot_mcp/http_message.gd")

var _tcp := TCPServer.new()
var _dispatch: Callable               # (body: String) -> String  ("" => notification, 202 no body)
var _clients: Dictionary = {}         # id -> {peer: StreamPeerTCP, buf: PackedByteArray}
var _next_id := 0

func _init(dispatch: Callable) -> void:
	_dispatch = dispatch

func start(port: int) -> int:
	return _tcp.listen(port, "127.0.0.1")

func get_port() -> int:
	return _tcp.get_local_port()

func is_listening() -> bool:
	return _tcp.is_listening()

func stop() -> void:
	for id in _clients:
		var c = _clients[id]
		if c["peer"] != null:
			c["peer"].disconnect_from_host()
	_clients.clear()
	if _tcp.is_listening():
		_tcp.stop()

# Call every frame (editor _process) or busy-loop (tests).
func poll() -> void:
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		_clients[_next_id] = {"peer": peer, "buf": PackedByteArray()}
		_next_id += 1
	var done := []
	for id in _clients:
		if _service_client(id):
			done.append(id)
	for id in done:
		_clients.erase(id)

# Returns true when the client is finished and should be removed.
func _service_client(id: int) -> bool:
	var c = _clients[id]
	var peer: StreamPeerTCP = c["peer"]
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return true
	var avail := peer.get_available_bytes()
	if avail > 0:
		var chunk: Array = peer.get_data(avail)
		c["buf"].append_array(chunk[1])
	var raw: String = c["buf"].get_string_from_utf8()
	var body_start := Http.header_end(raw)
	if body_start == -1:
		return false  # headers not complete yet
	var parsed := Http.parse_request(raw)
	if not parsed["ok"]:
		_send(peer, Http.build_response(400, "Bad Request", "text/plain"))
		return true
	var need := Http.content_length(parsed["headers"])
	if parsed["body"].to_utf8_buffer().size() < need:
		return false  # body still arriving
	_respond(peer, parsed)
	return true

func _respond(peer: StreamPeerTCP, parsed: Dictionary) -> void:
	if parsed["method"] != "POST" or not str(parsed["path"]).begins_with("/mcp"):
		_send(peer, Http.build_response(405, "Method Not Allowed", "text/plain"))
		return
	var out: String = _dispatch.call(parsed["body"])
	if out == "":
		_send(peer, Http.build_response(202, ""))
	else:
		_send(peer, Http.build_response(200, out))

func _send(peer: StreamPeerTCP, response_text: String) -> void:
	peer.put_data(response_text.to_utf8_buffer())
	peer.disconnect_from_host()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `godot4 --headless --path . --script addons/godot_mcp/tests/test_http_server.gd; echo "EXIT=$?"`
Expected: `=== 3 passed, 0 failed (test_http_server.gd) ===`, `EXIT=0`.

(If the loop occasionally needs more iterations on a slow machine, the 400-iteration / 2ms budget = ~0.8s per round trip is ample for loopback; the verified probe completed in well under 200 iterations.)

- [ ] **Step 5: Run the full suite, then commit**

Run: `./addons/godot_mcp/run_tests.sh; echo "RUNNER_EXIT=$?"`
Expected: `>>> suites failed: 0`, `RUNNER_EXIT=0`.

```bash
git add addons/godot_mcp/http_server.gd addons/godot_mcp/tests/test_http_server.gd
git commit -m "feat: TCPServer-based HTTP/1.1 server with poll loop"
```

---

## Task 10: EditorPlugin + manifest + end-to-end verification (`plugin.cfg`, `mcp_plugin.gd`)

Wire everything into a live editor plugin: on enable, register the plugin in `Engine` metadata (so `script_tools` can rescan the filesystem), build the `McpHandler`, start the `HttpServer` on the configured port, and call `poll()` every `_process`. On disable, stop the server. Then verify the whole stack with `curl` and `claude mcp`.

**Files:**
- Create: `addons/godot_mcp/plugin.cfg`
- Create: `addons/godot_mcp/mcp_plugin.gd`
- Modify: `project.godot` (enable the plugin)

- [ ] **Step 1: Create the plugin manifest**

Create `addons/godot_mcp/plugin.cfg`:

```ini
[plugin]

name="Godot MCP"
description="Pure-GDScript MCP server hosted in the Godot editor (HTTP transport)."
author="godot-mcp"
version="0.1.0"
script="mcp_plugin.gd"
```

- [ ] **Step 2: Write the EditorPlugin**

Create `addons/godot_mcp/mcp_plugin.gd`:

```gdscript
@tool
extends EditorPlugin

const HttpServer = preload("res://addons/godot_mcp/http_server.gd")
const McpHandler = preload("res://addons/godot_mcp/mcp_handler.gd")

const META_KEY := "GodotMCPPlugin"
const SETTING_PORT := "godot_mcp/port"
const DEFAULT_PORT := 8765

var _server
var _handler

func _enter_tree() -> void:
	Engine.set_meta(META_KEY, self)
	_handler = McpHandler.new()
	_server = HttpServer.new(Callable(_handler, "handle_message"))
	var port := _resolve_port()
	var err: int = _server.start(port)
	if err == OK:
		set_process(true)
		print("[godot-mcp] MCP HTTP server listening on http://127.0.0.1:%d/mcp" % port)
	else:
		set_process(false)
		printerr("[godot-mcp] Failed to listen on port %d (error %d)" % [port, err])

func _exit_tree() -> void:
	set_process(false)
	if _server != null:
		_server.stop()
	_server = null
	_handler = null
	if Engine.has_meta(META_KEY):
		Engine.remove_meta(META_KEY)

func _process(_delta: float) -> void:
	if _server != null and _server.is_listening():
		_server.poll()

func _resolve_port() -> int:
	if ProjectSettings.has_setting(SETTING_PORT):
		return int(ProjectSettings.get_setting(SETTING_PORT))
	return DEFAULT_PORT
```

- [ ] **Step 3: Confirm the plugin scripts parse cleanly (headless validation)**

Run a one-off validation that the editor-only scripts have no parse errors (they cannot be unit-tested headless because they need a live editor, but we can confirm they load):

```bash
godot4 --headless --path . --check-only --script addons/godot_mcp/mcp_plugin.gd; echo "EXIT=$?"
```
Expected: `EXIT=0` and no `SCRIPT ERROR` / `Parse Error` lines. (`--check-only` parses without running.)

- [ ] **Step 4: Run the full unit suite once more**

Run: `./addons/godot_mcp/run_tests.sh; echo "RUNNER_EXIT=$?"`
Expected: `>>> suites failed: 0`, `RUNNER_EXIT=0`.

- [ ] **Step 5: Enable the plugin and verify end-to-end against a live editor**

This step is **manual** — it needs a running editor (the server is only live while the editor is open). Open the project in the Godot editor:

```bash
godot4 --editor --path . &
```

Then enable the plugin: **Project → Project Settings → Plugins → "Godot MCP" → Enable** (this writes `enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")` into `project.godot`). The editor Output panel should show `[godot-mcp] MCP HTTP server listening on http://127.0.0.1:8765/mcp`.

Verify the MCP handshake with `curl` (run in a separate terminal):

```bash
# initialize
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```
Expected (single line): `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"godot-mcp","version":"0.1.0"}}}`

```bash
# tools/list
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```
Expected: a JSON object whose `result.tools` array contains all 6 tool names (`read_file`, `list_dir`, `search_project`, `create_script`, `edit_script`, `validate_script`).

```bash
# tools/call -> read_file on this plan's own project.godot
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"project.godot"}}}'
```
Expected: `result.isError` is `false` and `result.content[0].text` contains `config/name="Godot MCP"`.

- [ ] **Step 6: Connect Claude Code and confirm the tools are usable**

```bash
claude mcp add --transport http godot http://127.0.0.1:8765/mcp
claude mcp list
```
Expected: `godot` appears and is reachable. In a Claude Code session, confirm the 6 tools are listed and that asking Claude to read a project file invokes `read_file` successfully.

- [ ] **Step 7: Commit**

```bash
git add addons/godot_mcp/plugin.cfg addons/godot_mcp/mcp_plugin.gd project.godot
git commit -m "feat: editor plugin wiring the HTTP MCP server end-to-end"
```

---

## Self-Review

**1. Spec coverage (README v1 scope, file/script subset + foundation):**
- HTTP MCP server in-editor, Streamable HTTP, plain `POST → application/json` → Tasks 3, 8, 9, 10. ✓
- Loopback only, no auth → `start(port, "127.0.0.1")` in Task 9; default port 8765 overridable via `godot_mcp/port` in Task 10. ✓
- Pure GDScript, no Node/daemon/binary → entire plan; tests use only `godot4`. ✓
- Multi-instance (many clients connect to one server) → stateless per-request HTTP, per-client buffering in Task 9 `poll()`. ✓
- `read_file`, `list_dir`, `search_project` → Task 6. ✓
- `create_script`, `edit_script`, `validate_script` → Task 7. ✓
- Editor-must-be-open lifecycle → Task 10 EditorPlugin. ✓
- Connect via `claude mcp add --transport http` → Task 10 Step 6. ✓
- Deferred (correctly out of scope here): scene tools, run/feedback tools, runtime/v2 tools, bearer-token auth. These are follow-up plans.

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N" — every code step contains full code; every run step states the exact command and expected output. ✓

**3. Type consistency check across tasks:**
- Tool handler contract `{ok, value}`/`{ok, error}` — consistent in Task 6, 7, used by Task 5 `call_tool` and Task 8 registry wiring. ✓
- `Paths.validate()` returns `{ok, path, error}` (Task 2), consumed identically in Tasks 6 & 7. ✓
- `Http.parse_request()` keys (`ok, method, path, headers, body`), `Http.header_end()`, `Http.content_length()`, `Http.build_response()` — defined Task 3, consumed Task 9. ✓
- `JsonRpc.parse/result/error` shapes — defined Task 4, consumed Task 8. ✓
- `ToolRegistry.register/list_tools/call_tool` — defined Task 5, consumed Task 8. ✓
- `McpHandler.handle_message(text) -> String` and `PROTOCOL_VERSION` const — defined Task 8, consumed by Task 8 tests and Task 10 server wiring. ✓
- `HttpServer.new(dispatch: Callable)`, `start(port) -> int`, `get_port()`, `is_listening()`, `poll()`, `stop()` — defined Task 9, consumed Task 10. ✓
- Notification convention (`handle_message` returns `""` → server 202) consistent between Task 8 and Task 9. ✓

No naming drift found.

---

## Notes for the executor

- Run the **whole** suite (`./addons/godot_mcp/run_tests.sh`) after each task, not just the task's own suite, to catch cross-file regressions early.
- Reference implementation studied for the tool layer: `ee0pdt/Godot-MCP` (GDScript addon). Key adaptations vs. that reference: it uses WebSocket; we use plain HTTP/1.1 + `TCPServer`. It is command-dispatch based; we implement real MCP (`initialize`/`tools/list`/`tools/call`).
- The headless test invocation, the `TCPServer`+`StreamPeerTCP` loopback round-trip, and the `GDScript.reload()`+`Logger` validation approach were all empirically verified against Godot 4.6.1 before this plan was written.
- `--check-only` (Task 10 Step 3) is the way to parse-check editor-only scripts that can't run headless.
