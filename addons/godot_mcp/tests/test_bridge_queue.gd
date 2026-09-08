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

func test_quit_priority_preserves_partial_frame_only() -> void:
	var peer := Peer.new()
	peer._enqueue(PackedByteArray([1, 2, 3, 4]))
	peer._enqueue(PackedByteArray([5, 6]))
	peer._offset = 1
	peer._queued_bytes -= 1
	peer._enqueue(PackedByteArray([7]))
	peer.prioritize_last_frame()
	assert_eq(peer.pending_bytes(), 4)
	assert_eq(peer._out.size(), 2)
	assert_eq(peer._out[0], PackedByteArray([1, 2, 3, 4]))
	assert_eq(peer._out[1], PackedByteArray([7]))
	peer.disconnect_from_host()
func test_unsendable_reply_disconnects_instead_of_disappearing() -> void:
	var bridge = preload("res://addons/godot_mcp/runtime/game_bridge.gd").new()
	assert_false(bridge._reply("request", {"ok": true}))
	assert_eq(bridge._peer.get_status(), StreamPeerTCP.STATUS_NONE)
	bridge.free()

func test_quit_prevents_later_commands_in_same_batch() -> void:
	var bridge = preload("res://addons/godot_mcp/runtime/game_bridge.gd").new()
	bridge.session_id = "test"
	bridge._accepted = true
	var state := {"called": false}
	bridge.handlers["mutate"] = func(_args):
		state.called = true
		return {"ok": true}
	bridge._receive({"session_id": "test", "request_id": "1", "command": "quit", "args": {}})
	bridge._receive({"session_id": "test", "request_id": "2", "command": "mutate", "args": {}})
	assert_true(bridge._quitting)
	assert_false(state.called)
	bridge.free()

func test_invalid_frame_prevents_later_game_dispatch() -> void:
	var bridge = preload("res://addons/godot_mcp/runtime/game_bridge.gd").new()
	bridge.session_id = "test"
	bridge._accepted = true
	var state := {"called": false}
	bridge.handlers["mutate"] = func(_args):
		state.called = true
		return {"ok": true}
	bridge._receive({"session_id": "wrong"})
	bridge._receive({"session_id": "test", "request_id": "2", "command": "mutate", "args": {}})
	assert_true(bridge._closed)
	assert_false(state.called)
	bridge.free()
