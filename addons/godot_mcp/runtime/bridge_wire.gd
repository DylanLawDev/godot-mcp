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
	var offset := 0
	while offset < bytes.size() and error == "":
		# Fill one header/body at a time. Coalesced following frames never count
		# against the size limit of the currently incomplete frame.
		if buffer.size() < 4:
			var header_count := mini(4 - buffer.size(), bytes.size() - offset)
			buffer.append_array(bytes.slice(offset, offset + header_count))
			offset += header_count
			if buffer.size() < 4:
				break
		var n := (int(buffer[0]) << 24) | (int(buffer[1]) << 16) | (int(buffer[2]) << 8) | int(buffer[3])
		if n < 2 or n > MAX_BYTES:
			error = "Invalid bridge payload size"
			break
		var count := mini(n + 4 - buffer.size(), bytes.size() - offset)
		buffer.append_array(bytes.slice(offset, offset + count))
		offset += count
		if buffer.size() < n + 4:
			break
		var parsed: Variant = JSON.parse_string(buffer.slice(4).get_string_from_utf8())
		buffer.clear()
		if not parsed is Dictionary:
			error = "Bridge message must be a JSON object"
			break
		messages.append(parsed)
	return messages
