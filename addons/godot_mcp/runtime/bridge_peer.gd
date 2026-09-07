@tool
extends RefCounted
# A bounded nonblocking write queue; large images must not stall an editor frame.
const LIMIT := 16 * 1024 * 1024 + 4
var socket: StreamPeerTCP
var _out := PackedByteArray()

func _init(peer: StreamPeerTCP = null) -> void:
	socket = peer if peer != null else StreamPeerTCP.new()

func connect_to_host(host: String, port: int) -> Error:
	return socket.connect_to_host(host, port)

func poll() -> void:
	socket.poll()
	if socket.get_status() == StreamPeerTCP.STATUS_CONNECTED and not _out.is_empty():
		var written := socket.put_partial_data(_out.slice(0, mini(65536, _out.size())))
		if written[0] != OK:
			disconnect_from_host()
		elif written[1] > 0:
			_out = _out.slice(written[1])

func put_data(data: PackedByteArray) -> Error:
	if socket.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return ERR_CONNECTION_ERROR
	if _out.size() + data.size() > LIMIT:
		return ERR_OUT_OF_MEMORY
	_out.append_array(data)
	return OK

func get_status() -> int:
	return socket.get_status()

func get_available_bytes() -> int:
	return socket.get_available_bytes()

func get_data(count: int) -> Array:
	return socket.get_data(count)

func disconnect_from_host() -> void:
	_out.clear()
	socket.disconnect_from_host()
