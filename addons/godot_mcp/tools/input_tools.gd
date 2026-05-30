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
		var dict = ProjectSettings.get_setting(name)
		if typeof(dict) != TYPE_DICTIONARY:
			continue
		actions.append(_encode_action(name, dict))
	return {"ok": true, "value": {"actions": actions}}

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
