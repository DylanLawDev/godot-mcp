@tool
extends RefCounted

# Shared, editor-agnostic texture readback: resolve a Texture2D reachable from
# a node (a SubViewport's render target, or any node property holding one) and
# dump it to a PNG. Used by BOTH the editor tool (tools/scene_tools.gd
# capture_texture) and the runtime scenario engine's capture_texture step, so
# the readback subtleties have one home. Nothing here touches EditorInterface.

# Resolve the texture to read. With an empty property the node itself must be a
# SubViewport (its render target is captured); otherwise `property` is a
# get_indexed path ("texture", "material:albedo_texture") that must hold a
# Texture2D. Returns {ok, texture} or {ok: false, error}.
static func resolve_texture(node: Node, property: String) -> Dictionary:
	if node == null:
		return {"ok": false, "error": "No node to read a texture from"}
	if property.strip_edges() == "":
		if node is SubViewport:
			var tex := (node as SubViewport).get_texture()
			if tex == null:
				return {"ok": false, "error": "SubViewport has no render target texture"}
			return {"ok": true, "texture": tex}
		return {"ok": false, "error": "Node is not a SubViewport; pass 'property' naming a Texture2D property"}
	var value = node.get_indexed(NodePath(property))
	if value == null:
		return {"ok": false, "error": "Property '%s' is null or does not exist" % property}
	if not (value is Texture2D):
		return {"ok": false, "error": "Property '%s' is not a Texture2D (got %s)" % [property, str(typeof(value))]}
	return {"ok": true, "texture": value}

# Extract CPU image data from a texture. GPU-backed textures (ViewportTexture)
# have nothing to read on the headless display server — reading them there
# errors inside the engine and can crash on exit, so refuse up front.
# Compressed images (imported CompressedTexture2D) are decompressed, since
# Image.save_png rejects compressed formats. Returns {ok, image} or error.
static func to_image(tex: Texture2D) -> Dictionary:
	if tex == null:
		return {"ok": false, "error": "No texture to read"}
	if tex is ViewportTexture and DisplayServer.get_name() == "headless":
		return {"ok": false, "error": "Viewport textures render nothing headless (use a windowed run)"}
	var img := tex.get_image()
	if img == null or img.is_empty():
		return {"ok": false, "error": "Texture has no readable image data"}
	if img.is_compressed():
		var err := img.decompress()
		if err != OK:
			return {"ok": false, "error": "Could not decompress texture image (error %d)" % err}
	return {"ok": true, "image": img}

# Resolve + read + write in one call. `out_path` is any FileAccess-writable
# path (res://, user://, absolute); parent dirs are created. Returns
# {ok, path, width, height} or {ok: false, error}.
static func dump_to_png(node: Node, property: String, out_path: String) -> Dictionary:
	if out_path.strip_edges() == "":
		return {"ok": false, "error": "Output path is empty"}
	var resolved := resolve_texture(node, property)
	if not resolved["ok"]:
		return resolved
	var imaged := to_image(resolved["texture"])
	if not imaged["ok"]:
		return imaged
	var img: Image = imaged["image"]
	var dir := out_path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		var mk := DirAccess.make_dir_recursive_absolute(dir)
		if mk != OK:
			return {"ok": false, "error": "Could not create dir '%s' (error %d)" % [dir, mk]}
	var err := img.save_png(out_path)
	if err != OK:
		return {"ok": false, "error": "Failed to save PNG '%s' (error %d)" % [out_path, err]}
	return {"ok": true, "path": out_path, "width": img.get_width(), "height": img.get_height()}
