@tool
extends RefCounted

const _PREFIX := "input/"

# Read the project input map from ProjectSettings. Input actions are stored as
# settings whose key starts with "input/" and whose value is a Dictionary
# {"deadzone": float, "events": Array[InputEvent]}. Works fully headless.
func get_input_actions(_args: Dictionary) -> Dictionary:
	var actions := []
	for prop in ProjectSettings.get_property_list():
		var name := str(prop.get("name", ""))
		if not name.begins_with(_PREFIX):
			continue
		# Skip feature-tag overrides like "input/fire.macos": Godot stores per-platform
		# overrides of a base action with a ".<feature>" suffix. They aren't standalone
		# actions, and reporting "fire.macos" would be a phantom/duplicate action name.
		if "." in name.substr(_PREFIX.length()):
			continue
		var dict = ProjectSettings.get_setting(name)
		if typeof(dict) != TYPE_DICTIONARY:
			continue
		actions.append(_encode_action(name, dict))
	return {"ok": true, "value": {"actions": actions}}

# Create or update an input action in the project input map. Supports partial
# updates: omitting `events` or `deadzone` preserves the existing value.
func set_input_action(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", "")).strip_edges()
	if not _valid_action_name(name):
		return {"ok": false, "error": "Invalid action name: " + str(args.get("name", ""))}
	if args.has("deadzone") and not (typeof(args["deadzone"]) in [TYPE_FLOAT, TYPE_INT]):
		return {"ok": false, "error": "'deadzone' must be a number"}
	var key := _PREFIX + name
	var existing := {"deadzone": 0.5, "events": []}
	var cur = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	if typeof(cur) == TYPE_DICTIONARY:
		# Shallow-copy the events array; its InputEvent elements still alias the live
		# ProjectSettings objects, which is safe because we only read+rewrite them.
		existing = {"deadzone": float(cur.get("deadzone", 0.5)), "events": Array(cur.get("events", []))}
	var built := _build_action(existing, args)
	var action: Dictionary = built["action"]
	ProjectSettings.set_setting(key, action)
	# Persisting can fail (read-only checkout, permissions, disk error). Report it
	# instead of claiming success, and roll back the in-memory change so the editor's
	# state matches what's actually on disk. set_setting(key, null) removes a key that
	# didn't exist before; passing the prior dict restores an update.
	var err := ProjectSettings.save()
	if err != OK:
		ProjectSettings.set_setting(key, cur)
		return {"ok": false, "error": "Failed to save project.godot (error %d)" % err}
	return {"ok": true, "value": {
		"name": name,
		"deadzone": action["deadzone"],
		"event_count": action["events"].size(),
		"errors": built["errors"],
	}}

# Pure: an action name must be non-empty and free of characters that have meaning
# in the project.godot config or the "input/" key namespace (slashes, '=', control
# chars). Defense-in-depth in the spirit of paths.gd — junk names are useless anyway.
func _valid_action_name(name: String) -> bool:
	if name == "":
		return false
	for ch in ["/", "=", "\n", "\r", "\t", "[", "]"]:
		if ch in name:
			return false
	return true

# Pure: merge `args` over an existing {deadzone, events} action. `events` (if
# present) is an Array of var_to_str strings; each is parsed and kept only if it
# resolves to an InputEvent — invalid entries are collected into "errors".
func _build_action(existing: Dictionary, args: Dictionary) -> Dictionary:
	var deadzone := float(existing.get("deadzone", 0.5))
	var events: Array = Array(existing.get("events", []))
	var errors := []
	if args.has("deadzone"):
		deadzone = float(args["deadzone"])
	if args.has("events"):
		events = []
		for s in args["events"]:
			var parsed = str_to_var(str(s))
			if parsed is InputEvent:
				events.append(parsed)
			else:
				errors.append("Not an InputEvent: " + str(s))
	return {"action": {"deadzone": deadzone, "events": events}, "errors": errors}

# Pure: encode a single "input/<name>" setting Dictionary into a serializable
# action entry. Events become var_to_str strings (the encoding scene_tools uses).
func _encode_action(name: String, dict: Dictionary) -> Dictionary:
	var events := []
	for e in dict.get("events", []):
		events.append(var_to_str(e))
	return {
		"name": name.substr(_PREFIX.length()),
		"deadzone": float(dict.get("deadzone", 0.5)),
		"events": events,
	}
