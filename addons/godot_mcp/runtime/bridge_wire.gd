@tool
extends RefCounted
# Network-order uint32 length + UTF-8 JSON object; bounded input and output.
const MAX_BYTES := 16 * 1024 * 1024
var buffer := PackedByteArray()
var error := ""

static func encode(message: Dictionary) -> PackedByteArray:
	var payload := JSON.stringify(message).to_utf8_buffer()
	if payload.size() > MAX_BYTES:
		return PackedByteArray()
	var frame := PackedByteArray()
	var n := payload.size()
	frame.append_array(PackedByteArray([(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255]))
	frame.append_array(payload)
	return frame

func feed(bytes: PackedByteArray) -> Array:
	var messages := []
	if error != "":
		return messages
	if buffer.size() + bytes.size() > MAX_BYTES + 4:
		error = "Bridge buffer exceeds limit"
		return messages
	buffer.append_array(bytes)
	while buffer.size() >= 4:
		var n := (int(buffer[0]) << 24) | (int(buffer[1]) << 16) | (int(buffer[2]) << 8) | int(buffer[3])
		if n < 2 or n > MAX_BYTES:
			error = "Invalid bridge payload size"
			break
		if buffer.size() < n + 4:
			break
		var parsed: Variant = JSON.parse_string(buffer.slice(4, n + 4).get_string_from_utf8())
		buffer = buffer.slice(n + 4)
		if not parsed is Dictionary:
			error = "Bridge message must be a JSON object"
			break
		messages.append(parsed)
	return messages
