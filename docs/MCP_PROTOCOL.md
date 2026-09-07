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
