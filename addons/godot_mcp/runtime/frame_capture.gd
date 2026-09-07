@tool
extends RefCounted

# Writes numbered PNG frames (frame_0000.png, frame_0001.png, ...) into one
# output directory and accumulates a per-frame manifest. One instance per dir;
# the scenario engine owns instances, the runner calls capture() after pumping
# each frame of a capture_frames step.
#
# The headless display server has no rendered frames — reading the viewport
# texture there returns null after an engine error (and can crash on exit), so
# capture() refuses up front and records a manifest error instead. Real pixels
# need a windowed run: run_scenario.sh --render.

var dir := ""
var downscale := 1
var _seq := 0
var _frames: Array = []
var _errors := 0

# Prepare the output directory. Returns {ok, error}.
func configure(p_dir: String, p_downscale: int) -> Dictionary:
	if p_dir.strip_edges() == "":
		return {"ok": false, "error": "capture dir is empty"}
	dir = p_dir
	downscale = max(1, p_downscale)
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return {"ok": false, "error": "Could not create capture dir '%s' (error %d)" % [dir, err]}
	return {"ok": true, "error": ""}

# Grab the viewport's latest frame and save it. Always appends a manifest
# entry; failures are recorded, never raised.
func capture(viewport: Viewport) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return _error_entry("headless display server renders no frames (run with --render)")
	if viewport == null:
		return _error_entry("no viewport to capture")
	var tex := viewport.get_texture()
	if tex == null:
		return _error_entry("viewport has no texture")
	var img := tex.get_image()
	if img == null or img.is_empty():
		return _error_entry("viewport texture has no image")
	return save_image(img)

# Downscale + write one image as the next numbered frame. Split from capture()
# so the naming/downscale/manifest logic is unit-testable headless.
func save_image(img: Image) -> Dictionary:
	if img == null or img.is_empty():
		return _error_entry("image is empty")
	if downscale > 1:
		img.resize(
			max(1, img.get_width() / downscale),
			max(1, img.get_height() / downscale),
			Image.INTERPOLATE_BILINEAR)
	var file := dir.path_join("frame_%04d.png" % _seq)
	var err := img.save_png(file)
	if err != OK:
		return _error_entry("failed to save '%s' (error %d)" % [file, err])
	var entry := {"index": _seq, "file": file, "width": img.get_width(), "height": img.get_height()}
	_seq += 1
	_frames.append(entry)
	return entry

func _error_entry(msg: String) -> Dictionary:
	var entry := {"index": _seq, "error": msg}
	_seq += 1
	_errors += 1
	_frames.append(entry)
	return entry

func manifest() -> Dictionary:
	return {
		"dir": dir,
		"downscale": downscale,
		"captured": _frames.size() - _errors,
		"errors": _errors,
		"frames": _frames,
	}
