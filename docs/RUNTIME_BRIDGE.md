# Runtime foundation

The editor owns `runtime/session_manager.gd` via `Engine` metadata
`GodotMCPRuntime`. Tool handlers may inject a manager in tests. The manager owns
one interactive child and one background-job lane. It never adopts editor Play
processes. `launch(scene, headless, timeout)` uses saved project content and the
current Godot executable. No project settings or persistent autoloads are edited.
Godot loads existing project autoloads before the custom SceneTree bootstrap.

`summary(session_id)` returns a copy without private fields. Session states are
starting/running/stopping/exited/failed. `bridge_connected` is independent of
process liveness; a heartbeat timeout does not prove a crash. A nullable exit
code means the host could not supply one. Twenty completed records and 1,000
output chunks per process are retained. Artifacts live under
`user://godot_mcp/<random-id>/`; returned paths are globalized. Retention of
metadata does not automatically delete user artifacts.

## Wire contract

An ephemeral TCP port on 127.0.0.1 accepts a version-1 hello containing the random
session ID and random per-launch token. The editor replies accepted; the game
sends ready only after scene initialization. Frames are a big-endian uint32 byte
length followed by a UTF-8 JSON object (maximum 16 MiB). Reads, queued writes,
unauthenticated peers and pending requests are bounded. No listener is added to
normal exported games; the bridge exists only in the explicitly launched custom
bootstrap. Tokens are not returned in summaries.

Commands contain session_id, request_id, command and args. Replies contain kind
reply, session_id, request_id and result `{ok, value/error}`. The child exposes
only handlers registered by addon code, plus quit/cancel. It runs while the scene
is paused. Unknown commands, stale sessions and malformed replies cannot execute
an arbitrary method. Disconnect cancels outstanding operations. Plugin disable
closes the listener and terminates owned children.

## Deferred handlers

A tool can return `runtime/deferred_result.gd` instead of a completed Dictionary.
Call `resolve({ok, value/error})` exactly once. Optional `on_cancel` releases
operation resources. `session_manager.request(id, command, args, timeout)` creates
one automatically. The registry maps completion to the normal MCP result, then
`handle_message_async` maps it to JSON-RPC. The HTTP server retains the connection
while continuing to poll other clients; it sends one ordinary JSON response.
There is no SSE or MCP task extension. Legacy synchronous seams remain available
and reject/cancel deferred operations explicitly rather than blocking.

`process_jobs.gd` is the injectable OS seam: launch, poll, active, terminate,
shutdown and records. Pipe reads and bridge/HTTP writes are nonblocking. The
Linux Godot 4.6.1 integration checks actual pipes, autoload loading, paused
request handling and exit code collection. Windows/macOS require host validation.

## Validation

Run the full unit suite and the separate real-process fixture:

```sh
GODOT=/path/to/godot4 ./addons/godot_mcp/run_tests.sh
GODOT=/path/to/godot4 ./addons/godot_mcp/tests/run_runtime_integration.sh
```

Use writable XDG_DATA_HOME/XDG_CONFIG_HOME/XDG_CACHE_HOME directories when testing
in a sandbox. Loopback sockets must be permitted. The integration fixture is
headless; it does not claim screenshot/rendering coverage.
