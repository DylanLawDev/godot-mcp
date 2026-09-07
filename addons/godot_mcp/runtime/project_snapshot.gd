@tool
extends RefCounted
# Incremental saved-file copy/removal. No live import cache is touched.
const SKIP_DIRS := [".git", ".godot", "build", "builds", "dist"]
var source := ""
var target := ""
var done := false
var error := ""
var files_copied := 0
var _queue: Array[String] = [""]
var _directory: DirAccess
var _relative := ""
var _input: FileAccess
var _output: FileAccess
var _removing := false
var _remove_dirs: Array[String] = []
var _excluded: Array[String] = []

func _init(from: String, to: String, remove: bool = false) -> void:
	source = from
	target = to
	_removing = remove
	if not remove:
		var presets := ConfigFile.new()
		if presets.load(source.path_join("export_presets.cfg")) == OK:
			for section in presets.get_sections():
				var path: String = str(presets.get_value(section, "export_path", ""))
				if path != "":
					var absolute := path.replace("res://", source + "/") if path.begins_with("res://") else (path if path.is_absolute_path() else source.path_join(path))
					if absolute.simplify_path().begins_with(source + "/"):
						_excluded.append(absolute.simplify_path())

func poll() -> void:
	if done:
		return
	var started := Time.get_ticks_usec()
	var operations := 0
	while not done and operations < 128 and Time.get_ticks_usec() - started < 3000:
		operations += 1
		if _input != null:
			var expected := mini(262144, _input.get_length() - _input.get_position())
			var data := _input.get_buffer(expected)
			if data.size() != expected:
				_fail("Could not read saved project file")
				return
			_output.store_buffer(data)
			if _output.get_error() != OK:
				_fail("Could not write project snapshot")
				return
			if _input.get_position() >= _input.get_length():
				_input.close()
				_output.close()
				_input = null
				_output = null
				files_copied += 1
			continue
		if _directory != null:
			var name := _directory.get_next()
			if name == "":
				_directory.list_dir_end()
				_directory = null
				continue
			if name in [".", ".."]:
				continue
			var relative := _relative.path_join(name)
			var absolute := source.path_join(relative)
			var managed := ProjectSettings.globalize_path("user://godot_mcp").trim_suffix("/")
			if not _removing and (absolute == managed or absolute.begins_with(managed + "/")):
				continue
			if not _removing and (_directory.current_is_dir() and name in SKIP_DIRS or absolute in _excluded):
				continue
			if _directory.is_link(name):
				if _removing:
					if DirAccess.remove_absolute(absolute) != OK:
						_fail("Could not remove snapshot link")
				else:
					_fail("Snapshot does not support symbolic links: " + relative)
				continue
			_queue.append(relative)
			continue
		if _queue.is_empty():
			if _removing and not _remove_dirs.is_empty():
				if DirAccess.remove_absolute(_remove_dirs.pop_back()) != OK:
					_fail("Could not remove snapshot directory")
				continue
			done = true
			return
		var relative: String = _queue.pop_back()
		var absolute := source.path_join(relative)
		if DirAccess.dir_exists_absolute(absolute):
			_directory = DirAccess.open(absolute)
			if _directory != null:
				_directory.include_hidden = true
			if _directory == null or _directory.list_dir_begin() != OK:
				_fail("Could not enumerate snapshot directory: " + relative)
				return
			_relative = relative
			if _removing:
				_remove_dirs.append(absolute)
			elif DirAccess.make_dir_recursive_absolute(target.path_join(relative)) != OK:
				_fail("Could not create snapshot directory")
		elif _removing:
			if DirAccess.remove_absolute(absolute) != OK:
				_fail("Could not remove snapshot file")
		else:
			_input = FileAccess.open(absolute, FileAccess.READ)
			_output = FileAccess.open(target.path_join(relative), FileAccess.WRITE)
			if _input == null or _output == null:
				_fail("Could not copy saved file: " + relative)

func _fail(message: String) -> void:
	error = message
	done = true
	close()

func close() -> void:
	if _input != null:
		_input.close()
	if _output != null:
		_output.close()
	_input = null
	_output = null
	_directory = null

static func disable_mcp(path: String) -> Error:
	var config := ConfigFile.new()
	var loaded := config.load(path)
	if loaded != OK:
		return loaded
	var enabled: Variant = config.get_value("editor_plugins", "enabled", PackedStringArray())
	if not enabled is PackedStringArray and not enabled is Array:
		return ERR_INVALID_DATA
	var kept := PackedStringArray()
	for plugin in enabled:
		if plugin != "res://addons/godot_mcp/plugin.cfg":
			kept.append(plugin)
	config.set_value("editor_plugins", "enabled", kept)
	return config.save(path)
