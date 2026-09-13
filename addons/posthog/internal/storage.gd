extends RefCounted

const Utils = preload("utils.gd")
var _directory: String
var _enabled: bool
var _state: Dictionary = {}


func _init(config: PostHogConfig) -> void:
	_enabled = config.persistence
	_directory = config.storage_path.path_join((config.host + "|" + config.api_key).sha256_text())
	if not _enabled:
		return
	var error := DirAccess.make_dir_recursive_absolute(_directory.path_join("events"))
	if error != OK:
		Utils.warn("Cannot create storage directory; using opted-out, memory-only state")
		_state = {"opted_out": true}
		_enabled = false
		return
	var state_path := _directory.path_join("state.json")
	if FileAccess.file_exists(state_path):
		_state = {"opted_out": true}
	var loaded: Variant = _read_json(state_path)
	if (
		loaded is Dictionary
		and typeof(loaded.get("version")) in [TYPE_INT, TYPE_FLOAT]
		and loaded.version == 1
		and loaded.get("data") is Dictionary
	):
		_state = loaded.data


func get_value(key: String, fallback: Variant = null) -> Variant:
	var value: Variant = _state.get(key, fallback)
	return value.duplicate(true) if value is Dictionary or value is Array else value


func set_value(key: String, value: Variant) -> void:
	_state[key] = value.duplicate(true) if value is Dictionary or value is Array else value
	if _enabled:
		_write_json(_directory.path_join("state.json"), {"version": 1, "data": _state})


func load_events(limit: int) -> Array:
	var events: Array = []
	if not _enabled:
		return events
	var directory := DirAccess.open(_directory.path_join("events"))
	var names := directory.get_files()
	names.sort()
	for filename in names:
		if not filename.ends_with(".json"):
			continue
		var path := _directory.path_join("events").path_join(filename)
		var event: Variant = _read_json(path)
		if Utils.valid_event(event) and _event_filename(event.uuid) == filename:
			events.append(event)
		else:
			DirAccess.remove_absolute(path)
	while events.size() > limit:
		delete_event(events.pop_front().uuid)
	return events


func save_event(event: Dictionary) -> void:
	if _enabled:
		_write_json(_directory.path_join("events").path_join(_event_filename(event.uuid)), event)


func delete_event(id: String) -> void:
	if _enabled:
		DirAccess.remove_absolute(_directory.path_join("events").path_join(_event_filename(id)))


func _event_filename(id: String) -> String:
	# Preserve UUID ordering without allowing a before_send UUID to become a path.
	return id.validate_filename() + ".json"


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return null
	return json.data


func _write_json(path: String, value: Variant) -> void:
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		Utils.warn("Cannot write persistent state; data is only retained in memory")
		return
	file.store_string(JSON.stringify(value))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or DirAccess.rename_absolute(temporary, path) != OK:
		Utils.warn("Cannot commit persistent state; data is only retained in memory")
