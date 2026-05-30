# Headless Scenario Runner — Design

**Date:** 2026-05-30
**Status:** Approved, pending implementation

## Problem

The MCP server lets Claude read/edit code and manipulate the *edited* scene inside a
live editor, but it cannot **run** a game and observe behavior. The daily agent loop
(*read → edit → run → see errors*) is missing the "run" half. We want Claude to be able
to launch a headless Godot process that runs a real scene, drive it with input, set up
and inspect runtime node state, and get a machine-readable pass/fail verdict — without a
windowed editor and without screenshots (deferred).

The README already anticipates this as the v2 runtime layer (README:121: "runtime tools
need a second live connection from the running game").

## Decisions (from brainstorming)

These were settled with the user and are fixed for v1:

1. **Deterministic scenario runner, not live poking.** Claude authors a scenario file
   (target scene + ordered steps), launches it, and reads results. There is no
   interactive mid-run connection.
2. **Claude launches via Bash; one process per scenario.** A fresh headless process runs
   one scenario to completion and exits. No long-lived supervisor, no scene reloading
   within a process.
3. **No HTTP/MCP server in the game process.** Results come back as a **JSON file** that
   Claude reads with `read_file`/Bash. This supersedes the earlier "self-hosted MCP"
   idea — it is unnecessary for a run-to-completion flow.
4. **Action-based input only.** Inputs are driven through the project input map via
   `Input.action_press`/`action_release` (optional strength). Raw key/mouse
   `InputEvent` synthesis is a documented v2 extension.
5. **Built-in assertions.** Scenarios carry assert steps; the runner records per-assertion
   pass/fail and an overall verdict, making runs self-judging and CI-friendly.
6. **Reuse via extraction.** The root-parameterized node helpers in `scene_tools.gd` are
   extracted into a shared `utils/node_ops.gd`, used by both the editor scene tools and
   the runtime engine — one source of truth for the subtle type-coercion logic.

## Architecture

```
Claude writes scenario.json
   ↓ (Bash, background)
godot4 --headless --path . --script addons/godot_mcp/runtime/scenario_runner.gd
        -- --scenario <path> --out <path>
   ↓
scenario_runner.gd (SceneTree)  →  loads target scene, pumps frames, runs steps
   ↓
results.json  ←  Claude reads via read_file/Bash
```

The runner is launched exactly like the existing `run_tests.sh` suites (a `--script`
`SceneTree` main loop), reusing the project's established headless pattern. The game
process is fully decoupled from the editor — it does not require the editor to be open
and works in CI.

## Components

### `addons/godot_mcp/utils/node_ops.gd` (`RefCounted`, extracted)

The shared, editor-agnostic node helpers, moved out of `scene_tools.gd`:

- `resolve(root, path) -> Node` — root-relative NodePath resolution with traversal safety
  (rejects absolute paths and any node outside the root subtree).
- `serialize_tree(node, root) -> Dictionary` — recursive `{name,type,path,script,children}`.
- `encode_props(node) -> Dictionary` — all non-separator properties, `var_to_str`-encoded.
- `decode_props(node, props) -> {valid, errors}` — validates names against the property
  list, decodes values via `str_to_var`.
- `apply_props(node, props) -> {set, errors}` — sets decoded values, verifying each took.
- `value_applied(current, intended) -> bool` — type-safe "did the set take?" (no
  mismatched-Variant `==`, allows int/float coercion).
- `make_node(type, name) -> Node` — instantiate a `Node` subclass by class name, or null.

`scene_tools.gd` is refactored to call these instead of its private copies. This is a
**behavior-preserving** refactor; the existing `test_scene_tools.gd` suite is the guard,
plus a new `test_node_ops.gd` covering the helpers directly.

### `addons/godot_mcp/runtime/scenario_engine.gd` (`RefCounted`, testable)

Owns the loaded scene root and executes one step at a time, accumulating step outcomes,
assertion verdicts, and signal counters. It does **not** pump frames — the runner owns the
loop — so the engine is drivable directly from a plain headless test without launching a
process.

Key surface:

- `set_root(node)` / holds the current scene root.
- `execute(step) -> Dictionary` — runs a single non-waiting step, returns
  `{index, type, ok, detail}` (and, for asserts, the assertion record).
- Signal-watch state: `watch_signal` connects a counting callback; `signal_count` asserts
  read it.
- `results() -> Dictionary` — the accumulated results object (minus log/errors, which the
  runner attaches).

Waiting steps (`wait_frames`, `wait_seconds`) and the auto-release half of an
`input_action` `tap` are coordinated with the runner: `execute` for a wait step returns a
descriptor telling the runner how many frames to pump; `input_action` press/release call
`Input.*` directly.

### `addons/godot_mcp/runtime/scenario_runner.gd` (`SceneTree`, thin)

The live main loop. Responsibilities:

1. Parse `--scenario <path>` and `--out <path>` from `OS.get_cmdline_user_args()`.
2. Load + validate the scenario JSON (clear error → results with `ok:false` + exit non-zero).
3. Install the `output_capture.gd` ring-buffer `Logger` via `OS.add_logger` to capture the
   game's logs/errors during the run.
4. `load(scene).instantiate()`, add it under `root`, set as `current_scene`.
5. Iterate steps: pump frames for wait steps (await `process_frame`), delegate the rest to
   the engine.
6. Attach captured `errors` + `log` tail to the engine results; write JSON to `--out`.
7. Set exit code = `0` if `passed` else non-zero; `quit()`.

Kept thin enough to verify via the manual E2E doc rather than unit-testing the live loop.

### `addons/godot_mcp/runtime/run_scenario.sh` (wrapper)

Mirrors `run_tests.sh` (honors `$GODOT`, default `godot4`). One-line launch:

```bash
GODOT=godot4 addons/godot_mcp/runtime/run_scenario.sh <scenario.json> <out.json>
```

## Scenario format

```json
{
  "scene": "res://examples/player.tscn",
  "steps": [
    { "type": "wait_frames", "count": 2 },
    { "type": "watch_signal", "path": "Player", "signal": "died" },
    { "type": "input_action", "action": "move_right", "mode": "press" },
    { "type": "wait_seconds", "seconds": 0.5 },
    { "type": "input_action", "action": "move_right", "mode": "release" },
    { "type": "assert", "kind": "property", "path": "Player", "property": "position:x", "op": "gt", "value": "100" },
    { "type": "assert", "kind": "signal_count", "path": "Player", "signal": "died", "op": "eq", "value": 0 }
  ]
}
```

### Step types (v1)

| Type | Fields | Purpose |
|------|--------|---------|
| `wait_frames` | `count` | Advance the SceneTree N frames |
| `wait_seconds` | `seconds` | Advance ~T seconds of frames |
| `input_action` | `action`, `mode` (`press`/`release`/`tap`), `strength?` | Drive a project-input-map action; validates the action exists in `InputMap`. `tap` = press then auto-release the next frame |
| `set_property` | `path`, `properties:{…}` | Arrange test conditions (via `node_ops.apply_props`) |
| `call_method` | `path`, `method`, `args?` | Invoke a node method, capture the return value |
| `create_node` | `parent_path`, `node_type`, `name`, `properties?` | Build test conditions (via `node_ops.make_node`, no undo). `node_type` carries the node class; `type` stays the step discriminator |
| `delete_node` | `path` | Tear down test conditions |
| `watch_signal` | `path`, `signal` | Begin counting a signal's emissions (must precede a `signal_count` assert) |
| `assert` | `kind`, … | The verdict-bearing step (below) |

### Assertion kinds

- `property` — `{path, property, op ∈ eq/ne/lt/le/gt/ge, value}`; compared with the
  type-safe `value_applied` coercion semantics. `property` supports `:`-subpaths
  (e.g. `position:x`).
- `node_exists` / `node_absent` — `{path}`.
- `in_group` — `{path, group}`.
- `signal_count` — `{path, signal, op, value}`; reads a counter registered by an earlier
  `watch_signal`.

### Results JSON shape

```json
{
  "scene": "res://examples/player.tscn",
  "ok": true,
  "passed": false,
  "frames_run": 34,
  "steps":      [ { "index": 0, "type": "input_action", "ok": true,  "detail": "…" } ],
  "assertions": [ { "index": 5, "kind": "property", "path": "Player", "expected": "> 100", "actual": "87.0", "passed": false } ],
  "errors":     [ /* engine errors captured via the Logger during the run */ ],
  "log":        [ /* tail of captured stdout/log lines */ ]
}
```

- `ok` — the scenario ran to completion with no fatal/setup error (bad scene path,
  malformed scenario, unresolved node in a non-assert step).
- `passed` — every assertion passed. Exit code mirrors `passed`.

## v1 limitations (documented, not bugs)

- **Action input is poll-observable only.** `Input.action_press` is visible via
  `is_action_pressed`/`is_action_just_pressed` but does **not** fire `_input`/
  `_unhandled_input`. Event-driven (non-polling) handlers won't trigger in v1. Raw
  `InputEvent` synthesis (keys, mouse) is a v2 extension.
- **No screenshots / no rendering assertions.** Out of scope by request.
- **No mouse.** Deferred with raw events.

## Testing

- `tests/test_node_ops.gd` — direct coverage of the extracted helpers.
- `tests/test_scene_tools.gd` — unchanged; guards the behavior-preserving refactor.
- `tests/test_scenario_engine.gd` — builds an in-memory scene + step list, drives
  `scenario_engine.gd` directly (no process launch), asserts step outcomes, assertion
  verdicts (each `op`, each `kind`), signal counting, and error/`ok:false` paths.
- `runtime/scenario_runner.gd`'s live frame loop is exercised via the manual E2E doc
  (`docs/E2E_TESTING.md`) with an `examples/` fixture scene.

## Out of scope (v2+)

Raw key/mouse `InputEvent` injection, `_input` delivery, screenshots, long-lived
interactive sessions, in-process scene reloading, a self-hosted runtime MCP endpoint.
