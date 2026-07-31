@tool
extends RefCounted

# Builds raw InputEvents from scenario step dictionaries. Construction only —
# it never dispatches (the engine owns that via Input.parse_input_event) — but
# mouse events READ Input.get_mouse_button_mask() so `button_mask` reflects the
# buttons held by earlier synthesized presses: handlers that gate dragging or
# chords on the mask see the same state the poll API reports.
#
# Returns {"ok": true, "event": InputEvent, "detail": String} or
# {"ok": false, "error": String}.

const MOUSE_BUTTONS := {
	"left": MOUSE_BUTTON_LEFT,
	"right": MOUSE_BUTTON_RIGHT,
	"middle": MOUSE_BUTTON_MIDDLE,
	"wheel_up": MOUSE_BUTTON_WHEEL_UP,
	"wheel_down": MOUSE_BUTTON_WHEEL_DOWN,
	"wheel_left": MOUSE_BUTTON_WHEEL_LEFT,
	"wheel_right": MOUSE_BUTTON_WHEEL_RIGHT,
	"xbutton1": MOUSE_BUTTON_XBUTTON1,
	"xbutton2": MOUSE_BUTTON_XBUTTON2,
}

static func build(step: Dictionary) -> Dictionary:
	var kind := str(step.get("kind", ""))
	match kind:
		"key":
			return _build_key(step)
		"mouse_button":
			return _build_mouse_button(step)
		"mouse_motion":
			return _build_mouse_motion(step)
		"action":
			return _build_action(step)
		_:
			return {"ok": false, "error": "Unknown input_event kind: " + kind}

# Accepts human key names as understood by OS.find_keycode_from_string
# ("A", "Left", "Escape", "F1"), plus the constant-style "KEY_LEFT" spelling.
static func parse_key_name(name: String) -> Key:
	var s := name.strip_edges()
	if s.begins_with("KEY_"):
		s = s.substr(4).capitalize()
	var code := OS.find_keycode_from_string(s)
	return code

static func _build_key(step: Dictionary) -> Dictionary:
	var name := str(step.get("key", ""))
	if name == "":
		return {"ok": false, "error": "input_event key requires 'key'"}
	var code := parse_key_name(name)
	if code == KEY_NONE:
		return {"ok": false, "error": "Unknown key name: " + name}
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = bool(step.get("pressed", true))
	ev.echo = bool(step.get("echo", false))
	# Printable keycodes (KEY_SPACE..KEY_ASCIITILDE) equal their ASCII codepoint;
	# carrying it as unicode lets LineEdit-style consumers receive the character.
	if ev.pressed and code >= KEY_SPACE and code <= KEY_ASCIITILDE:
		ev.unicode = code
	_apply_modifiers(ev, step)
	return {"ok": true, "event": ev, "detail": "key %s %s" % [OS.get_keycode_string(code), "press" if ev.pressed else "release"]}

static func _build_mouse_button(step: Dictionary) -> Dictionary:
	var name := str(step.get("button", ""))
	if not MOUSE_BUTTONS.has(name):
		return {"ok": false, "error": "Unknown mouse button: '%s' (expected one of %s)" % [name, ", ".join(MOUSE_BUTTONS.keys())]}
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTONS[name]
	ev.pressed = bool(step.get("pressed", true))
	ev.double_click = bool(step.get("double_click", false))
	var pos := _parse_vec2(step.get("position", null))
	if pos["ok"]:
		ev.position = pos["value"]
		ev.global_position = pos["value"]
	elif step.has("position"):
		return {"ok": false, "error": "'position' must be a [x, y] array"}
	# Start from the currently-held mask (as tracked by Input after earlier
	# dispatches) and add/remove this event's own bit, mirroring OS events.
	# Wheel "buttons" are momentary and have no mask bit; they carry the held
	# mask unchanged.
	var mask := int(Input.get_mouse_button_mask())
	var bit := _mask_bit(ev.button_index)
	ev.button_mask = (mask | bit) if ev.pressed else (mask & ~bit)
	_apply_modifiers(ev, step)
	return {"ok": true, "event": ev, "detail": "mouse %s %s at %s" % [name, "press" if ev.pressed else "release", str(ev.position)]}

static func _mask_bit(button: MouseButton) -> int:
	match button:
		MOUSE_BUTTON_LEFT: return MOUSE_BUTTON_MASK_LEFT
		MOUSE_BUTTON_RIGHT: return MOUSE_BUTTON_MASK_RIGHT
		MOUSE_BUTTON_MIDDLE: return MOUSE_BUTTON_MASK_MIDDLE
		MOUSE_BUTTON_XBUTTON1: return MOUSE_BUTTON_MASK_MB_XBUTTON1
		MOUSE_BUTTON_XBUTTON2: return MOUSE_BUTTON_MASK_MB_XBUTTON2
	return 0

static func _build_mouse_motion(step: Dictionary) -> Dictionary:
	var ev := InputEventMouseMotion.new()
	var pos := _parse_vec2(step.get("position", null))
	if pos["ok"]:
		ev.position = pos["value"]
		ev.global_position = pos["value"]
	elif step.has("position"):
		return {"ok": false, "error": "'position' must be a [x, y] array"}
	var rel := _parse_vec2(step.get("relative", null))
	if rel["ok"]:
		ev.relative = rel["value"]
	elif step.has("relative"):
		return {"ok": false, "error": "'relative' must be a [x, y] array"}
	var vel := _parse_vec2(step.get("velocity", null))
	if vel["ok"]:
		ev.velocity = vel["value"]
	elif step.has("velocity"):
		return {"ok": false, "error": "'velocity' must be a [x, y] array"}
	# Motion during a synthesized drag must report the held buttons.
	ev.button_mask = int(Input.get_mouse_button_mask())
	_apply_modifiers(ev, step)
	return {"ok": true, "event": ev, "detail": "mouse motion to %s (rel %s)" % [str(ev.position), str(ev.relative)]}

static func _build_action(step: Dictionary) -> Dictionary:
	var action := str(step.get("action", ""))
	if action == "":
		return {"ok": false, "error": "input_event action requires 'action'"}
	if not InputMap.has_action(action):
		return {"ok": false, "error": "No such input action: " + action}
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = bool(step.get("pressed", true))
	ev.strength = clampf(float(step.get("strength", 1.0)), 0.0, 1.0)
	return {"ok": true, "event": ev, "detail": "action %s %s (%.2f)" % [action, "press" if ev.pressed else "release", ev.strength]}

static func _apply_modifiers(ev: InputEventWithModifiers, step: Dictionary) -> void:
	var mods = step.get("modifiers", [])
	if typeof(mods) != TYPE_ARRAY:
		return
	for m in mods:
		match str(m):
			"shift": ev.shift_pressed = true
			"ctrl": ev.ctrl_pressed = true
			"alt": ev.alt_pressed = true
			"meta": ev.meta_pressed = true

static func _parse_vec2(raw) -> Dictionary:
	if typeof(raw) != TYPE_ARRAY or (raw as Array).size() != 2:
		return {"ok": false}
	var a: Array = raw
	if not (typeof(a[0]) in [TYPE_INT, TYPE_FLOAT] and typeof(a[1]) in [TYPE_INT, TYPE_FLOAT]):
		return {"ok": false}
	return {"ok": true, "value": Vector2(float(a[0]), float(a[1]))}
