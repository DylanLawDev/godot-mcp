extends "res://addons/godot_mcp/tests/test_case.gd"

const TextureDump = preload("res://addons/godot_mcp/utils/texture_dump.gd")

const OUT_DIR := "user://_texture_dump_test"

func _tex(w: int, h: int, color := Color.RED) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)

func _wipe() -> void:
	var da := DirAccess.open(OUT_DIR)
	if da != null:
		for f in da.get_files():
			da.remove(f)
	DirAccess.remove_absolute(OUT_DIR)

# --- resolve_texture ---

func test_resolve_from_property() -> void:
	var n := Sprite2D.new()
	n.texture = _tex(4, 4)
	var r := TextureDump.resolve_texture(n, "texture")
	assert_true(r["ok"])
	assert_eq(r["texture"], n.texture)
	n.free()

func test_resolve_subviewport_without_property() -> void:
	var vp := SubViewport.new()
	var r := TextureDump.resolve_texture(vp, "")
	# Headless the render target may exist as a ViewportTexture object.
	assert_true(r["ok"])
	assert_true(r["texture"] is ViewportTexture)
	vp.free()

func test_resolve_non_viewport_without_property_rejected() -> void:
	var n := Node2D.new()
	var r := TextureDump.resolve_texture(n, "")
	assert_false(r["ok"])
	assert_has(r["error"], "SubViewport")
	n.free()

func test_resolve_missing_property_rejected() -> void:
	var n := Node2D.new()
	assert_false(TextureDump.resolve_texture(n, "no_such_prop")["ok"])
	n.free()

func test_resolve_non_texture_property_rejected() -> void:
	var n := Node2D.new()
	var r := TextureDump.resolve_texture(n, "position")
	assert_false(r["ok"])
	assert_has(r["error"], "not a Texture2D")
	n.free()

func test_resolve_null_node_rejected() -> void:
	assert_false(TextureDump.resolve_texture(null, "texture")["ok"])

# --- to_image ---

func test_to_image_from_image_texture() -> void:
	var r := TextureDump.to_image(_tex(6, 3))
	assert_true(r["ok"])
	assert_eq((r["image"] as Image).get_size(), Vector2i(6, 3))

func test_to_image_viewport_texture_headless_refused() -> void:
	# The guard must refuse BEFORE touching the dummy renderer (reading a
	# ViewportTexture headless errors in-engine and can crash on exit).
	var vp := SubViewport.new()
	var tex := vp.get_texture()
	var r := TextureDump.to_image(tex)
	assert_false(r["ok"])
	assert_has(r["error"], "headless")
	vp.free()

func test_to_image_null_rejected() -> void:
	assert_false(TextureDump.to_image(null)["ok"])

# --- dump_to_png ---

func test_dump_to_png_writes_file_with_dims() -> void:
	_wipe()
	var n := Sprite2D.new()
	n.texture = _tex(8, 5, Color.BLUE)
	var out := OUT_DIR + "/tex.png"
	var r := TextureDump.dump_to_png(n, "texture", out)
	assert_true(r["ok"])
	assert_eq(r["width"], 8)
	assert_eq(r["height"], 5)
	assert_true(FileAccess.file_exists(out))
	var loaded := Image.load_from_file(out)
	assert_eq(loaded.get_size(), Vector2i(8, 5))
	assert_eq(loaded.get_pixel(0, 0), Color.BLUE)
	n.free()
	_wipe()

func test_dump_to_png_creates_parent_dirs() -> void:
	_wipe()
	var n := Sprite2D.new()
	n.texture = _tex(2, 2)
	var out := OUT_DIR + "/tex2.png"
	assert_false(DirAccess.dir_exists_absolute(OUT_DIR))
	assert_true(TextureDump.dump_to_png(n, "texture", out)["ok"])
	assert_true(FileAccess.file_exists(out))
	n.free()
	_wipe()

func test_dump_to_png_empty_out_rejected() -> void:
	var n := Sprite2D.new()
	n.texture = _tex(2, 2)
	assert_false(TextureDump.dump_to_png(n, "texture", " ")["ok"])
	n.free()

func test_dump_to_png_propagates_resolve_error() -> void:
	var n := Node2D.new()
	var r := TextureDump.dump_to_png(n, "position", OUT_DIR + "/x.png")
	assert_false(r["ok"])
	assert_has(r["error"], "not a Texture2D")
	n.free()
