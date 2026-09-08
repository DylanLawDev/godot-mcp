extends SceneTree
const Bridge = preload("res://addons/godot_mcp/runtime/game_bridge.gd")
const Capture = preload("res://addons/godot_mcp/tools/output_capture.gd")
var logger

func _initialize() -> void:
	logger = Capture.new()
	OS.add_logger(logger)
	var args := {}
	var argv := OS.get_cmdline_user_args()
	for i in range(0, argv.size() - 1, 2):
		args[argv[i]] = argv[i + 1]
	if not args.has("--mcp-port") or not args.has("--mcp-token") or not args.has("--mcp-session") or not args.has("--mcp-scene"):
		push_error("Missing runtime bootstrap arguments")
		quit(2)
		return
	_start.call_deferred(args)

func _start(args: Dictionary) -> void:
	var bridge := Bridge.new()
	bridge.configure(args, logger)
	root.add_child(bridge)
	var packed = load(args["--mcp-scene"])
	if not packed is PackedScene:
		push_error("Could not load runtime scene: " + str(args["--mcp-scene"]))
		quit(2)
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	bridge.scene_ready = true
