#!/usr/bin/env python3
"""Cross-version HTTP wire checks against a real headless Godot fixture."""

from __future__ import annotations

import argparse
import http.client
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time

from jsonschema import validate

LEGACY = "2025-06-18"
MODERN = "2026-07-28"


def modern_request(request_id, method, params=None, version=MODERN):
    values = dict(params or {})
    values["_meta"] = {
        "io.modelcontextprotocol/protocolVersion": version,
        "io.modelcontextprotocol/clientCapabilities": {},
        "io.modelcontextprotocol/clientInfo": {"name": "wire-test", "version": "1"},
    }
    return {"jsonrpc": "2.0", "id": request_id, "method": method, "params": values}


def headers_for(message):
    method = message["method"]
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": message["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"],
        "Mcp-Method": method,
    }
    if method == "tools/call":
        headers["Mcp-Name"] = message["params"]["name"]
    elif method == "resources/read":
        headers["Mcp-Name"] = message["params"]["uri"]
    return headers


class Fixture:
    def __init__(self, godot: str, root: Path):
        self.user_dir = tempfile.TemporaryDirectory(prefix="godot-mcp-wire-")
        env = os.environ.copy()
        env["XDG_DATA_HOME"] = self.user_dir.name
        self.process = subprocess.Popen(
            [godot, "--headless", "--path", str(root), "--script", "addons/godot_mcp/tests/protocol_fixture_server.gd"],
            cwd=root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 15
        output = []
        self.port = None
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.process.stdout], [], [], 0.25)
            if not ready:
                if self.process.poll() is not None:
                    break
                continue
            line = self.process.stdout.readline()
            output.append(line)
            if line.startswith("MCP_FIXTURE_PORT="):
                self.port = int(line.split("=", 1)[1])
                break
        if self.port is None:
            self.close()
            raise RuntimeError("fixture failed to start:\n" + "".join(output))

    def request(self, message, headers=None):
        body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.request("POST", "/mcp", body=body, headers=headers or {"Content-Type": "application/json"})
        response = connection.getresponse()
        payload = response.read()
        connection.close()
        return response.status, json.loads(payload) if payload else None

    def close(self):
        if getattr(self, "process", None) is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if getattr(self, "user_dir", None) is not None:
            self.user_dir.cleanup()


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True)
    parser.add_argument("--schema", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    schema = json.loads(args.schema.read_text())
    fixture = Fixture(args.godot, root)
    try:
        # Legacy handshake, notification, catalog, call, and resource read.
        status, initialized = fixture.request({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "unknown", "capabilities": {}}})
        check(status == 200 and initialized["id"] == 0 and isinstance(initialized["id"], int), "integer ID changed JSON type")
        check(initialized["result"]["protocolVersion"] == LEGACY, "legacy version was echoed or changed")
        status, payload = fixture.request({"jsonrpc": "2.0", "method": "notifications/initialized"})
        check(status == 202 and payload is None, "legacy notification response")
        for message in [
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_project_info", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 4, "method": "resources/list", "params": {}},
            {"jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": {"uri": "godot://project/info"}},
        ]:
            status, payload = fixture.request(message)
            check(status == 200 and "result" in payload, f"legacy {message['method']}")

        # Modern direct calls without a handshake, interleaved with legacy.
        modern_cases = [
            ("server/discover", {}, "DiscoverResult"),
            ("tools/list", {}, "ListToolsResult"),
            ("tools/call", {"name": "get_project_info", "arguments": {}}, "CallToolResult"),
            ("resources/list", {}, "ListResourcesResult"),
            ("resources/read", {"uri": "godot://project/info"}, "ReadResourceResult"),
            ("resources/templates/list", {}, "ListResourceTemplatesResult"),
        ]
        for index, (method, params, definition) in enumerate(modern_cases, 10):
            message = modern_request(index, method, params)
            status, payload = fixture.request(message, headers_for(message))
            check(status == 200 and payload["result"]["resultType"] == "complete", f"modern {method}")
            validate(payload["result"], {"$ref": f"#/$defs/{definition}", "$defs": schema["$defs"]})
        discover = modern_request(20, "server/discover")
        _, payload = fixture.request(discover, headers_for(discover))
        check(payload["result"]["supportedVersions"] == [LEGACY, MODERN], "discovery version matrix")
        check(set(payload["result"]["capabilities"]) == {"tools", "resources"}, "capability over-advertising")

        # Required failures and status mappings.
        missing_header = modern_request(21, "tools/list")
        status, payload = fixture.request(missing_header)
        check(status == 400 and payload["error"]["code"] == -32020, "missing routing headers")
        unsupported = modern_request(22, "tools/list", version="2099-01-01")
        status, payload = fixture.request(unsupported, headers_for(unsupported))
        check(status == 400 and payload["error"]["code"] == -32022, "unsupported version")
        unknown = modern_request(23, "sampling/createMessage")
        status, payload = fixture.request(unknown, headers_for(unknown))
        check(status == 404 and payload["error"]["code"] == -32601, "unsupported optional method")
        origin_message = modern_request(24, "tools/list")
        origin_headers = headers_for(origin_message)
        origin_headers["Origin"] = "http://attacker.example"
        status, _ = fixture.request(origin_message, origin_headers)
        check(status == 403, "disallowed Origin")
    finally:
        fixture.close()
    print("wire conformance: legacy + modern matrix passed")


if __name__ == "__main__":
    main()
