@tool
extends RefCounted
# A bounded nonblocking write queue; large images must not stall an editor frame.
const LIMIT := 16 * 1024 * 1024 + 4
var socket: StreamPeerTCP
var _out: Array[PackedByteArray] = []
var _offset := 0
var _queued_bytes := 0

func _init(peer: StreamPeerTCP = null) -> void:
	socket = peer if peer != null else StreamPeerTCP.new()

func connect_to_host(host: String, port: int) -> Error:
	return socket.connect_to_host(host, port)

func poll() -> void:
	socket.poll()
	if socket.get_status() == StreamPeerTCP.STATUS_CONNECTED and not _out.is_empty():
		var frame: PackedByteArray = _out[0]
		var written := socket.put_partial_data(frame.slice(_offset, mini(_offset + 65536, frame.size())))
		if written[0] != OK:
			disconnect_from_host()
		elif written[1] > 0:
			_offset += int(written[1])
			_queued_bytes -= int(written[1])
			if _offset >= frame.size():
				_out.pop_front()
				_offset = 0

func put_data(data: PackedByteArray) -> Error:
	if socket.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return ERR_CONNECTION_ERROR
	return _enqueue(data)

func _enqueue(data: PackedByteArray) -> Error:
	# Separate per-frame validity from bounded aggregate backpressure.
	if data.size() > LIMIT or _out.size() >= 256 or _queued_bytes + data.size() > 4 * LIMIT:
		return ERR_OUT_OF_MEMORY
	if not data.is_empty():
		_out.append(data)
		_queued_bytes += data.size()
	return OK

func get_status() -> int:
	return socket.get_status()

func get_available_bytes() -> int:
	return socket.get_available_bytes()

func get_data(count: int) -> Array:
	return socket.get_data(count)

func disconnect_from_host() -> void:
	_out.clear()
	_offset = 0
	_queued_bytes = 0
	socket.disconnect_from_host()

func pending_bytes() -> int:
	return _queued_bytes
