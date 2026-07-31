extends Node2D
# Manual-E2E fixture for texture readback (capture_texture step). Builds a
# CPU-side ImageTexture in _ready (works headless) and hosts a SubViewport
# whose render target only has pixels in a --render run.

var cpu_tex: Texture2D = null

func _ready() -> void:
	var img := Image.create(16, 12, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.7, 0.3))
	cpu_tex = ImageTexture.create_from_image(img)
