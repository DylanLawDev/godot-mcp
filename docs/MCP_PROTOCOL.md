# MCP protocol architecture

The editor plugin hosts one HTTP endpoint at `http://127.0.0.1:<port>/mcp`.
Protocol selection and client capabilities are derived from each request; the
server deliberately keeps no global "last client" or negotiated-session state.

## Loopback Origin policy

The listener remains bound to `127.0.0.1`. Native clients may omit `Origin`.
When `Origin` is present, the server accepts exactly one value and it must be
the exact same-origin HTTP URL for the active listener: either
`http://127.0.0.1:<port>` or `http://localhost:<port>`. Opaque `null`, HTTPS,
credentials, paths, queries, remote or lookalike hosts, a different port,
multiple space-separated origins, and duplicate Origin fields are rejected
with HTTP 403 before MCP dispatch.

Origin validation mitigates browser DNS-rebinding requests. It is not client
authentication and does not make the loopback service safe for remote exposure.

## Versions, routing, and caching

The server supports legacy `2025-06-18` and modern `2026-07-28`. Legacy
`initialize` always selects the supported legacy revision rather than echoing
an arbitrary request. Modern requests carry the fully-qualified protocol
version and client-capabilities keys in `params._meta`; metadata is evaluated
per request and never becomes tool arguments or shared client state.

Modern HTTP requests also carry `MCP-Protocol-Version` and `Mcp-Method` headers.
`tools/call` and `resources/read` additionally carry `Mcp-Name`; non-ASCII or
otherwise unsafe names use the specification's `=?base64?...?=` sentinel.
Header errors return HTTP 400 / JSON-RPC `-32020`, unsupported versions return
400 / `-32022`, and unknown modern methods return 404 / `-32601`.

Every modern success result contains `resultType: "complete"` and server
identity metadata. Discovery, tool/resource catalogs, resource reads, and the
empty resource-template catalog carry `ttlMs: 0` and `cacheScope: "private"`.
The server advertises only tools and resources. It does not implement prompts,
subscriptions, tasks, sampling, server-to-client multi-round-trip workflows,
or OAuth.

## Requirements-to-test checklist

| Requirement | Code and verification |
|---|---|
| JSON-RPC request/notification validation and IDs | `jsonrpc.gd`; `test_jsonrpc.gd`, `test_mcp_handler.gd` |
| Per-request version/capability metadata and discovery | `mcp_handler.gd`; handler and wire conformance tests |
| Modern result identity, result type, and cache hints | `mcp_handler.gd`; schema-backed wire result matrix |
| Required routing headers and Base64 sentinel | `mcp_handler.gd`; `test_http_server.gd` |
| Exact `/mcp` POST endpoint and status mapping | `http_server.gd`; HTTP and wire tests |
| Loopback bind and Origin validation | `http_server.gd`; allowed/rejected Origin matrix |
| Legacy compatibility and no cross-client state | interleaved handler and wire tests |
| Advertised tools/resources methods are implemented | 56-tool registration regression in `test_mcp_handler.gd` plus catalog/call/read wire tests |
| Unsupported optional features fail without hanging | unknown optional-method wire test; not advertised |

The CI wire fixture starts a separate bounded headless Godot process on an
ephemeral loopback port with isolated user data. It validates selected result
types against the pinned official 2026-07-28 JSON schema and runs on Godot 4.6.1
and 4.7.1. Desktop client behavior remains a separate manual integration check.
