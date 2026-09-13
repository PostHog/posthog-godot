extends Node
## PostHog autoload. All public methods must be called on the main thread.

signal feature_flags_loaded
signal feature_flags_request_finished(success: bool)
signal events_dropped(count: int, reason: String)

const Config = preload("posthog_config.gd")
const Utils = preload("internal/utils.gd")
const Storage = preload("internal/storage.gd")
const Transport = preload("internal/transport.gd")
const EventQueue = preload("internal/event_queue.gd")
const Session = preload("internal/session.gd")
const FeatureFlags = preload("internal/feature_flags.gd")
const ErrorLogger = preload("internal/error_logger.gd")

var is_initialized: bool = false
var is_opted_out: bool = true
var distinct_id: String:
	get:
		return _identity.get("distinct_id", "")
var session_id: String:
	get:
		return _session.get_id() if is_initialized and not is_opted_out else ""
var queued_event_count: int:
	get:
		return _queue.events.size() if is_initialized else 0
var feature_flags_are_loaded: bool:
	get:
		return _flags.is_loaded if is_initialized else false

var _config: PostHogConfig
var _storage: RefCounted
var _transport: Node
var _queue: Node
var _flags: Node
var _session := Session.new()
var _identity: Dictionary = {}
var _super_properties: Dictionary = {}
var _person_properties: Dictionary = {}
var _group_properties: Dictionary = {}
var _logger: Logger
var _backgrounded: bool = false
var _quitting: bool = false
var _owns_quit: bool = false
var _in_before_send: bool = false
var _setup_generation: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var config_path: String = ProjectSettings.get_setting("posthog/config", "")
	if not config_path.is_empty() and not is_initialized:
		var resource := load(config_path)
		if resource is PostHogConfig:
			setup(resource)
		else:
			Utils.warn("posthog/config must point to a PostHogConfig resource")


func setup(config: PostHogConfig) -> bool:
	if is_initialized:
		Utils.warn("Already initialized; call shutdown before setting up again")
		return false
	if config == null or not is_inside_tree():
		Utils.warn("setup requires a config and a Node inside the scene tree")
		return false
	var error := config.validation_error()
	if not error.is_empty():
		Utils.warn(error)
		return false
	_config = config.duplicate(true)
	_config.before_send = config.before_send
	_config.host = _config.host.trim_suffix("/")
	_storage = Storage.new(_config)
	_identity = _load_dictionary("identity")
	if not _identity.get("anonymous_id") is String or _identity.get("anonymous_id", "").is_empty():
		_identity = {"anonymous_id": Utils.uuid_v7(), "identified": false, "groups": {}}
	if not _identity.get("distinct_id") is String or _identity.get("distinct_id", "").is_empty():
		_identity.distinct_id = _identity.anonymous_id
		_identity.identified = false
	if not _identity.get("groups") is Dictionary:
		_identity.groups = {}
	for key in _identity.groups.keys():
		if not _identity.groups[key] is String:
			_identity.groups.erase(key)
	_identity.identified = _identity.get("identified") is bool and _identity.identified
	_super_properties = _load_dictionary("super_properties")
	_person_properties = _load_dictionary("person_properties")
	_group_properties = _load_dictionary("group_properties")
	for key in _group_properties.keys():
		if not _group_properties[key] is Dictionary:
			_group_properties.erase(key)
	var consent: Variant = _storage.get_value("opted_out", _config.opt_out_by_default)
	is_opted_out = consent if consent is bool else true
	_storage.set_value("identity", _identity)
	_transport = Transport.new()
	_transport.config = _config
	add_child(_transport)
	_queue = EventQueue.new()
	_queue.config = _config
	_queue.storage = _storage
	_queue.transport = _transport
	add_child(_queue)
	_queue.initialize()
	_queue.events_dropped.connect(
		func(count: int, reason: String): events_dropped.emit(count, reason)
	)
	_flags = FeatureFlags.new()
	_flags.config = _config
	_flags.storage = _storage
	_flags.transport = _transport
	_flags.context = _flag_context
	_flags.capture = capture
	_flags.enabled = not is_opted_out
	add_child(_flags)
	_flags.loaded.connect(func(): feature_flags_loaded.emit())
	_flags.request_finished.connect(
		func(success: bool): feature_flags_request_finished.emit(success)
	)
	_session = Session.new()
	_backgrounded = false
	_quitting = false
	is_initialized = true
	_setup_generation += 1
	if is_opted_out:
		_queue.clear()
		_flags.invalidate()
	else:
		_flags.initialize()
		if _flags.is_loaded:
			_emit_cached_flags.call_deferred(_setup_generation)
		_start_logger()
		_capture_startup()
		if _config.preload_feature_flags:
			_preload_flags.call_deferred(_setup_generation)
	_owns_quit = _config.flush_on_quit and get_tree().auto_accept_quit
	if _owns_quit:
		get_tree().auto_accept_quit = false
	return true


func capture(event_name: String, properties: Dictionary = {}) -> void:
	if not _can_capture() or event_name.strip_edges().is_empty() or _in_before_send:
		return
	if not Utils.is_json(properties):
		Utils.warn("Event properties must contain only finite JSON values")
		return
	var props := _super_properties.duplicate(true)
	props.merge(properties.duplicate(true), true)
	props.merge(_default_properties(), true)
	props["$is_identified"] = _identity.identified
	props["$process_person_profile"] = (
		_config.person_profiles == Config.PersonProfiles.ALWAYS
		or (
			_config.person_profiles == Config.PersonProfiles.IDENTIFIED_ONLY
			and _identity.identified
		)
	)
	var current_session: String = _session.get_id()
	if not current_session.is_empty():
		props["$session_id"] = current_session
	if not _identity.groups.is_empty():
		props["$groups"] = _identity.groups.duplicate(true)
	var id := Utils.uuid_v7()
	var event: Variant = {
		"event": event_name,
		"distinct_id": distinct_id,
		"properties": props,
		"timestamp": Utils.timestamp(),
		"uuid": id
	}
	if _config.before_send.is_valid():
		_in_before_send = true
		event = _config.before_send.call(event)
		_in_before_send = false
	if event == null or not _can_capture():
		return
	if not Utils.valid_event(event):
		Utils.warn("before_send returned an invalid event; dropping it")
		return
	# The UUID is the durable queue key and must remain unique across retries.
	event.uuid = id
	_queue.enqueue(event.duplicate(true))
	_session.touch()


func screen(screen_name: String, properties: Dictionary = {}) -> void:
	if screen_name.strip_edges().is_empty():
		return
	var props := properties.duplicate(true)
	props["$screen_name"] = screen_name
	capture("$screen", props)


func identify(user_id: String, properties: Dictionary = {}, set_once: Dictionary = {}) -> bool:
	if not _can_capture() or _config.person_profiles == Config.PersonProfiles.NEVER:
		return false
	if (
		user_id.strip_edges().is_empty()
		or not Utils.is_json(properties)
		or not Utils.is_json(set_once)
	):
		return false
	var previous_anonymous: String = _identity.anonymous_id if not _identity.identified else ""
	if user_id != distinct_id and _identity.identified:
		_person_properties.clear()
	_identity.distinct_id = user_id
	_identity.identified = true
	_person_properties.merge(set_once.duplicate(true), false)
	_person_properties.merge(properties.duplicate(true), true)
	_storage.set_value("identity", _identity)
	_storage.set_value("person_properties", _person_properties)
	_flags.invalidate()
	var props: Dictionary = {}
	if not previous_anonymous.is_empty() and previous_anonymous != user_id:
		props["$anon_distinct_id"] = previous_anonymous
	if not properties.is_empty():
		props["$set"] = properties
	if not set_once.is_empty():
		props["$set_once"] = set_once
	capture("$identify", props)
	if _config.preload_feature_flags:
		return await reload_feature_flags()
	return true


func alias(alias_id: String) -> void:
	if (
		_can_capture()
		and _config.person_profiles != Config.PersonProfiles.NEVER
		and not alias_id.strip_edges().is_empty()
	):
		capture("$create_alias", {"alias": alias_id})


func group(group_type: String, group_key: String, properties: Dictionary = {}) -> void:
	if (
		not _can_capture()
		or group_type.strip_edges().is_empty()
		or group_key.strip_edges().is_empty()
	):
		return
	if not Utils.is_json(properties):
		return
	if _identity.groups.get(group_type) != group_key:
		_group_properties.erase(group_type)
	_identity.groups[group_type] = group_key
	var existing: Dictionary = _group_properties.get(group_type, {})
	existing.merge(properties.duplicate(true), true)
	_group_properties[group_type] = existing
	_storage.set_value("identity", _identity)
	_storage.set_value("group_properties", _group_properties)
	_flags.invalidate()
	var props := {"$group_type": group_type, "$group_key": group_key}
	if not properties.is_empty():
		props["$group_set"] = properties
	capture("$groupidentify", props)
	if _config.preload_feature_flags:
		reload_feature_flags()


func reset() -> bool:
	if not is_initialized:
		return false
	var anonymous: String = (
		_identity.anonymous_id if _config.reuse_anonymous_id else Utils.uuid_v7()
	)
	_identity = {
		"anonymous_id": anonymous, "distinct_id": anonymous, "identified": false, "groups": {}
	}
	_super_properties.clear()
	_person_properties.clear()
	_group_properties.clear()
	_storage.set_value("identity", _identity)
	_storage.set_value("super_properties", {})
	_storage.set_value("person_properties", {})
	_storage.set_value("group_properties", {})
	_session.reset()
	_flags.invalidate()
	if not is_opted_out and _config.preload_feature_flags:
		return await reload_feature_flags()
	return true


func register(key: String, value: Variant) -> void:
	if _can_capture() and not key.strip_edges().is_empty() and Utils.is_json(value):
		_super_properties[key] = (
			value.duplicate(true) if value is Dictionary or value is Array else value
		)
		_storage.set_value("super_properties", _super_properties)


func unregister(key: String) -> void:
	if is_initialized:
		_super_properties.erase(key)
		_storage.set_value("super_properties", _super_properties)


func opt_out() -> void:
	if not is_initialized:
		return
	is_opted_out = true
	_storage.set_value("opted_out", true)
	_stop_logger()
	_flags.enabled = false
	_flags.invalidate()
	_queue.clear()
	_session.reset()


func opt_in() -> void:
	if not is_initialized or not is_opted_out:
		return
	is_opted_out = false
	_storage.set_value("opted_out", false)
	_queue.running = true
	_flags.enabled = true
	_start_logger()
	if _config.preload_feature_flags:
		reload_feature_flags()


func flush() -> bool:
	if not _can_capture():
		return false
	return await _queue.flush()


func reload_feature_flags() -> bool:
	if not _can_capture():
		return false
	return await _flags.reload()


func get_feature_flag(key: String, send_event: bool = true) -> PostHogFeatureFlag:
	if not _can_capture():
		return PostHogFeatureFlag.new()
	return _flags.get_flag(key, send_event)


func is_feature_enabled(key: String, default_value: bool = false) -> bool:
	var flag := get_feature_flag(key)
	return flag.is_enabled if flag.has_value else default_value


func get_feature_flag_payload(key: String, default_value: Variant = null) -> Variant:
	return get_feature_flag(key).get_payload(default_value)


func set_person_properties_for_flags(properties: Dictionary, reload_flags: bool = true) -> void:
	if not _can_capture() or not Utils.is_json(properties):
		return
	_person_properties.merge(properties.duplicate(true), true)
	_storage.set_value("person_properties", _person_properties)
	_flags.invalidate()
	if reload_flags:
		reload_feature_flags()


func reset_person_properties_for_flags(reload_flags: bool = true) -> void:
	if not is_initialized:
		return
	_person_properties.clear()
	_storage.set_value("person_properties", {})
	_flags.invalidate()
	if reload_flags:
		reload_feature_flags()


func set_group_properties_for_flags(
	group_type: String, properties: Dictionary, reload_flags: bool = true
) -> void:
	if not _can_capture() or group_type.strip_edges().is_empty() or not Utils.is_json(properties):
		return
	var existing: Dictionary = _group_properties.get(group_type, {})
	existing.merge(properties.duplicate(true), true)
	_group_properties[group_type] = existing
	_storage.set_value("group_properties", _group_properties)
	_flags.invalidate()
	if reload_flags:
		reload_feature_flags()


func reset_group_properties_for_flags(group_type: String = "", reload_flags: bool = true) -> void:
	if not is_initialized:
		return
	if group_type.is_empty():
		_group_properties.clear()
	else:
		_group_properties.erase(group_type)
	_storage.set_value("group_properties", _group_properties)
	_flags.invalidate()
	if reload_flags:
		reload_feature_flags()


func capture_exception(
	message: String,
	properties: Dictionary = {},
	exception_type: String = "Error",
	stack: Array = [],
	handled: bool = true
) -> void:
	if not _can_capture() or message.strip_edges().is_empty():
		return
	var frames: Array = []
	var source_frames: Array = get_stack().slice(1) if stack.is_empty() else stack
	for frame in source_frames.slice(0, 50):
		if not frame is Dictionary:
			continue
		var filename := str(frame.get("source", ""))
		frames.append(
			{
				"filename": filename,
				"function": str(frame.get("function", "")),
				"lineno": int(frame.get("line", 0)),
				"in_app":
				filename.begins_with("res://") and not filename.begins_with("res://addons/")
			}
		)
	frames.reverse()
	var props := properties.duplicate(true)
	props.merge(
		{
			"$exception_type": exception_type,
			"$exception_message": message,
			"$exception_level": "error",
			"$exception_source": "godot_sdk",
			"$exception_handled": handled,
			"$exception_list":
			[
				{
					"type": exception_type,
					"value": message,
					"mechanism":
					{"type": "generic", "handled": handled, "source": "godot", "synthetic": true},
					"stacktrace": {"type": "raw", "frames": frames}
				}
			]
		},
		true
	)
	capture("$exception", props)


## Stops immediately, retaining unsent events on disk. Call await flush() first when needed.
func shutdown() -> void:
	if not is_initialized:
		return
	is_initialized = false
	_setup_generation += 1
	is_opted_out = true
	_stop_logger()
	_flags.enabled = false
	_flags.invalidate(false)
	_queue.stop()
	_flags.queue_free()
	_queue.queue_free()
	_transport.queue_free()
	if _owns_quit and is_inside_tree():
		get_tree().auto_accept_quit = true
	_owns_quit = false
	_session.reset()
	_identity.clear()


## Unlike SceneTree.quit(), waits briefly for delivery. Unsent events remain on disk.
func quit(exit_code: int = 0) -> void:
	if _quitting:
		return
	_quitting = true
	if _can_capture() and _config.flush_on_quit:
		var deadline := Time.get_ticks_msec() + int(_config.flush_on_quit_timeout_seconds * 1000)
		flush()
		while is_initialized and _queue.flushing and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
	shutdown()
	get_tree().quit(exit_code)


func _notification(what: int) -> void:
	if not is_initialized:
		return
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _owns_quit:
		quit()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_set_backgrounded(true)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_APPLICATION_RESUMED:
		_set_backgrounded(false)


func _process(_delta: float) -> void:
	if _logger != null:
		for error in _logger.drain():
			capture_exception(error.message, {}, error.type, error.frames, false)


func _exit_tree() -> void:
	shutdown()


func _can_capture() -> bool:
	return is_initialized and not is_opted_out


func _load_dictionary(key: String) -> Dictionary:
	var value: Variant = _storage.get_value(key, {})
	return value if value is Dictionary else {}


func _default_properties() -> Dictionary:
	var size := get_viewport().get_visible_rect().size
	return {
		"$lib": Utils.LIBRARY,
		"$lib_version": Utils.VERSION,
		"$os": OS.get_name(),
		"$os_version": OS.get_version(),
		"$device_type": "Mobile" if OS.has_feature("mobile") else "Desktop",
		"$device_model": OS.get_model_name(),
		"$screen_width": int(size.x),
		"$screen_height": int(size.y),
		"$app_name": ProjectSettings.get_setting("application/config/name", ""),
		"$app_version": _app_version(),
		"$app_build": _config.app_build,
		"$godot_version": Engine.get_version_info().string,
		"$locale": OS.get_locale()
	}


func _flag_context() -> Dictionary:
	var body := {
		"api_key": _config.api_key,
		"distinct_id": distinct_id,
		"$groups": _identity.groups.duplicate(true)
	}
	if not _config.reuse_anonymous_id:
		body["$anon_distinct_id"] = _identity.anonymous_id
	var properties: Dictionary = {}
	if _config.send_default_person_properties_for_flags:
		properties = {
			"$app_version": _app_version(),
			"$app_build": _config.app_build,
			"$os_name": OS.get_name(),
			"$os_version": OS.get_version(),
			"$device_type": "Mobile" if OS.has_feature("mobile") else "Desktop",
			"$lib": Utils.LIBRARY,
			"$lib_version": Utils.VERSION
		}
	properties.merge(_person_properties.duplicate(true), true)
	body.person_properties = properties
	body.group_properties = _group_properties.duplicate(true)
	return body


func _app_version() -> String:
	return (
		_config.app_version
		if not _config.app_version.is_empty()
		else str(ProjectSettings.get_setting("application/config/version", ""))
	)


func _capture_startup() -> void:
	var previous := _load_dictionary("lifecycle")
	var current := {"version": _app_version(), "build": _config.app_build}
	if _config.capture_application_lifecycle_events:
		if previous.is_empty():
			capture("Application Installed", current)
		elif previous != current:
			var updated := current.duplicate()
			updated.previous_version = previous.get("version", "")
			updated.previous_build = previous.get("build", "")
			capture("Application Updated", updated)
		var opened := current.duplicate()
		opened.from_background = false
		capture("Application Opened", opened)
	_storage.set_value("lifecycle", current)


func _set_backgrounded(value: bool) -> void:
	if _backgrounded == value:
		return
	_backgrounded = value
	_session.set_foreground(not value)
	if _can_capture() and _config.capture_application_lifecycle_events:
		var props := {"version": _app_version(), "build": _config.app_build}
		if not value:
			props.from_background = true
		capture("Application Backgrounded" if value else "Application Opened", props)
	if value:
		flush()


func _start_logger() -> void:
	if (
		not _config.capture_exceptions
		or (OS.has_feature("editor") and not _config.capture_exceptions_in_editor)
	):
		return
	_logger = ErrorLogger.new()
	_logger.debounce_ms = _config.exception_debounce_interval_ms
	OS.add_logger(_logger)


func _stop_logger() -> void:
	if _logger != null:
		_logger.disable()
		OS.remove_logger(_logger)
		_logger = null


func _emit_cached_flags(generation: int) -> void:
	if generation == _setup_generation and _can_capture() and _flags.is_loaded:
		feature_flags_loaded.emit()


func _preload_flags(generation: int) -> void:
	if generation == _setup_generation and _can_capture():
		reload_feature_flags()
