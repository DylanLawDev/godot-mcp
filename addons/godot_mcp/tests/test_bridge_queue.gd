extends "res://addons/godot_mcp/tests/test_case.gd"
const Peer = preload("res://addons/godot_mcp/runtime/bridge_peer.gd")
func test_full_frame_can_follow_queued_heartbeat() -> void:
	var peer := Peer.new()
	assert_eq(peer._enqueue(PackedByteArray([0, 0, 0, 1, 123])), OK)
	var frame := PackedByteArray()
	frame.resize(Peer.LIMIT)
	assert_eq(peer._enqueue(frame), OK)
	assert_eq(peer.pending_bytes(), Peer.LIMIT + 5)
	frame.resize(Peer.LIMIT + 1)
	assert_eq(peer._enqueue(frame), ERR_OUT_OF_MEMORY)
	peer.disconnect_from_host()
	assert_eq(peer.pending_bytes(), 0)
