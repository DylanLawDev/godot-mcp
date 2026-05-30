@tool
extends RefCounted

const Paths = preload("res://addons/godot_mcp/utils/paths.gd")

const _NO_WINDOW := "Screenshots require a windowed editor"

# --- Seams ---

func _capture():
	return Engine.get_meta("GodotMCPOutputCapture") if Engine.has_meta("GodotMCPOutputCapture") else null

func _plugin():
	return Engine.get_meta("GodotMCPPlugin") if Engine.has_meta("GodotMCPPlugin") else null

# --- Public tools ---

func get_output_log(args: Dictionary) -> Dictionary:
	var cap = _capture()
	if cap == null:
		return {"ok": true, "value": {"entries": []}}
	return {"ok": true, "value": {"entries": cap.entries(int(args.get("limit", 0)), bool(args.get("errors_only", false)))}}

# Clears OUR ring-buffer capture, NOT the editor's Output dock (Godot exposes no
# public API to read or clear the Output dock).
func clear_output(_args: Dictionary) -> Dictionary:
	var cap = _capture()
	if cap == null:
		return {"ok": true, "value": {"cleared": false}}
	cap.clear()
	return {"ok": true, "value": {"cleared": true}}

func get_editor_errors(args: Dictionary) -> Dictionary:
	var cap = _capture()
	if cap == null:
		return {"ok": true, "value": {"errors": []}}
	return {"ok": true, "value": {"errors": cap.entries(int(args.get("limit", 0)), true)}}

func get_editor_screenshot(args: Dictionary) -> Dictionary:
	var p = _plugin()
	if p == null:
		return {"ok": false, "error": _NO_WINDOW}
	var image = null
	# Defensive: in --headless the viewport/texture is null/dummy. Avoid crashing.
	var base = p.get_editor_interface().get_base_control()
	if base != null:
		var vp = base.get_viewport()
		if vp != null:
			var tex = vp.get_texture()
			if tex != null:
				image = tex.get_image()
	if image == null:
		return {"ok": false, "error": _NO_WINDOW}
	if args.has("path"):
		var v := Paths.validate(str(args.get("path", "")))
		if not v["ok"]:
			return {"ok": false, "error": v["error"]}
		var err: int = image.save_png(v["path"])
		if err != OK:
			return {"ok": false, "error": "Failed to save screenshot (error %d)" % err}
		return {"ok": true, "value": {"path": v["path"]}}
	return {"ok": true, "value": {"png_base64": Marshalls.raw_to_base64(image.save_png_to_buffer())}}

# Triggers a filesystem rescan so external edits are picked up by the editor.
func reload_project(_args: Dictionary) -> Dictionary:
	var p = _plugin()
	if p == null:
		return {"ok": true, "value": {"reloaded": false}}
	p.get_editor_interface().get_resource_filesystem().scan()
	return {"ok": true, "value": {"reloaded": true}}
