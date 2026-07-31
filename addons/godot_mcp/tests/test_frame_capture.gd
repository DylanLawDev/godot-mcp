extends "res://addons/godot_mcp/tests/test_case.gd"

const FrameCapture = preload("res://addons/godot_mcp/runtime/frame_capture.gd")

const TEST_DIR := "user://_frame_capture_test"

func _fresh_dir(suffix: String) -> String:
	var d := TEST_DIR + "_" + suffix
	_wipe(d)
	return d

func _wipe(d: String) -> void:
	var da := DirAccess.open(d)
	if da != null:
		for f in da.get_files():
			da.remove(f)
	DirAccess.remove_absolute(d)

func _img(w: int, h: int) -> Image:
	return Image.create(w, h, false, Image.FORMAT_RGB8)

func test_configure_creates_dir() -> void:
	var d := _fresh_dir("mkdir")
	var cap := FrameCapture.new()
	var r := cap.configure(d, 1)
	assert_true(r["ok"])
	assert_true(DirAccess.dir_exists_absolute(d))
	_wipe(d)

func test_configure_rejects_empty_dir() -> void:
	var cap := FrameCapture.new()
	assert_false(cap.configure("", 1)["ok"])
	assert_false(cap.configure("   ", 1)["ok"])

func test_configure_clamps_downscale() -> void:
	var d := _fresh_dir("clamp")
	var cap := FrameCapture.new()
	cap.configure(d, 0)
	assert_eq(cap.downscale, 1)
	_wipe(d)

func test_save_image_sequences_filenames() -> void:
	var d := _fresh_dir("seq")
	var cap := FrameCapture.new()
	cap.configure(d, 1)
	var e0 := cap.save_image(_img(8, 6))
	var e1 := cap.save_image(_img(8, 6))
	assert_true(str(e0["file"]).ends_with("frame_0000.png"))
	assert_true(str(e1["file"]).ends_with("frame_0001.png"))
	assert_true(FileAccess.file_exists(e0["file"]))
	assert_true(FileAccess.file_exists(e1["file"]))
	assert_eq(e0["width"], 8)
	assert_eq(e0["height"], 6)
	_wipe(d)

func test_save_image_downscales() -> void:
	var d := _fresh_dir("scale")
	var cap := FrameCapture.new()
	cap.configure(d, 2)
	var e := cap.save_image(_img(16, 10))
	assert_eq(e["width"], 8)
	assert_eq(e["height"], 5)
	# The written PNG really has the downscaled size.
	var loaded := Image.load_from_file(e["file"])
	assert_eq(loaded.get_size(), Vector2i(8, 5))
	_wipe(d)

func test_save_image_downscale_never_hits_zero() -> void:
	var d := _fresh_dir("tiny")
	var cap := FrameCapture.new()
	cap.configure(d, 8)
	var e := cap.save_image(_img(4, 4))
	assert_eq(e["width"], 1)
	assert_eq(e["height"], 1)
	_wipe(d)

func test_save_empty_image_records_error() -> void:
	var d := _fresh_dir("empty")
	var cap := FrameCapture.new()
	cap.configure(d, 1)
	var e := cap.save_image(null)
	assert_true(e.has("error"))
	var m := cap.manifest()
	assert_eq(m["errors"], 1)
	assert_eq(m["captured"], 0)
	_wipe(d)

func test_capture_headless_records_error_not_crash() -> void:
	# The unit suite runs headless, so this exercises the display-server guard:
	# capture() must refuse before touching the (dummy) viewport texture.
	var d := _fresh_dir("headless")
	var cap := FrameCapture.new()
	cap.configure(d, 1)
	var e := cap.capture(null)
	assert_true(e.has("error"))
	assert_has(str(e["error"]), "headless")

func test_manifest_shape() -> void:
	var d := _fresh_dir("manifest")
	var cap := FrameCapture.new()
	cap.configure(d, 3)
	cap.save_image(_img(9, 9))
	cap.save_image(null)
	var m := cap.manifest()
	assert_eq(m["dir"], d)
	assert_eq(m["downscale"], 3)
	assert_eq(m["captured"], 1)
	assert_eq(m["errors"], 1)
	assert_eq((m["frames"] as Array).size(), 2)
	# Indices stay globally sequential across successes and errors.
	assert_eq(m["frames"][0]["index"], 0)
	assert_eq(m["frames"][1]["index"], 1)
	_wipe(d)
