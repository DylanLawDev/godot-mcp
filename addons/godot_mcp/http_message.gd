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
