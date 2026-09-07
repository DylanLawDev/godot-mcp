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

func test_parse_preserves_duplicate_header_values() -> void:
	var raw := "POST /mcp HTTP/1.1\r\nOrigin: http://localhost:1\r\nORIGIN: http://localhost:2\r\nContent-Length: 0\r\n\r\n"
	var r := Http.parse_request(raw)
	assert_eq(r["header_values"]["origin"], ["http://localhost:1", "http://localhost:2"])

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
