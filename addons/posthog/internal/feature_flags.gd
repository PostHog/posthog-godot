extends Node

signal loaded
signal request_finished(success: bool)

var config: PostHogConfig
var storage: RefCounted
var transport: Node
var context: Callable
var capture: Callable
var enabled: bool = true
var loading: bool = false
var is_loaded: bool = false
var _cache: Dictionary = {}
var _called: Dictionary = {}
var _generation: int = 0
var _request: HTTPRequest


func initialize() -> void:
	var saved: Variant = storage.get_value("flags", {})
	if (
		saved is Dictionary
		and saved.get("context") is Dictionary
		and saved.context == context.call()
		and saved.get("response") is Dictionary
	):
		_apply(saved.response)


func reload() -> bool:
	if not enabled:
		return false
	if loading:
		return await request_finished
	loading = true
	_fetch.call_deferred(_generation, context.call(), 0)
	return await request_finished


func invalidate(clear_cache: bool = true) -> void:
	_generation += 1
	transport.cancel(_request)
	_request = null
	_called.clear()
	if clear_cache:
		_cache.clear()
		is_loaded = false
		storage.set_value("flags", {})
	if loading:
		loading = false
		request_finished.emit(false)


func get_flag(key: String, send_event: bool = true) -> PostHogFeatureFlag:
	var flag := PostHogFeatureFlag.new()
	flag.key = key
	var flags: Dictionary = _cache.get("flags", {})
	var legacy: Dictionary = _cache.get("featureFlags", {})
	var details: Dictionary = flags.get(key, {}) if flags.get(key) is Dictionary else {}
	if not details.is_empty():
		var metadata: Dictionary = (
			details.get("metadata", {}) if details.get("metadata") is Dictionary else {}
		)
		flag.metadata = metadata.duplicate(true)
		if details.get("failed") == true:
			flag.metadata.erase("payload")
		if details.get("failed") != true and details.get("enabled") is bool:
			flag.value = (
				details.get("variant")
				if details.enabled and details.get("variant") is String
				else details.enabled
			)
		if details.get("failed") != true:
			flag.payload = metadata.get("payload")
	elif legacy.get(key) is bool or legacy.get(key) is String:
		flag.value = legacy[key]
	if flag.payload == null and details.get("failed") != true:
		var payloads: Dictionary = _cache.get("featureFlagPayloads", {})
		flag.payload = payloads.get(key)
	if flag.payload is String:
		var json := JSON.new()
		if json.parse(flag.payload) == OK:
			flag.payload = json.data
	if flag.payload is Dictionary or flag.payload is Array:
		flag.payload = flag.payload.duplicate(true)
	if (
		enabled
		and send_event
		and config.send_feature_flag_event
		and (flag.has_value or details.get("failed") == true)
	):
		_track(flag, details)
	return flag


func _fetch(generation: int, body: Dictionary, attempt: int) -> void:
	if generation != _generation or not enabled:
		return
	_request = transport.post(
		"/flags/?v=2",
		body,
		func(result: int, status: int, _headers: PackedStringArray, response: String):
			if generation != _generation:
				return
			_request = null
			if result == HTTPRequest.RESULT_SUCCESS and status >= 200 and status < 300:
				var json := JSON.new()
				var success := (
					json.parse(response) == OK and json.data is Dictionary and _apply(json.data)
				)
				if success:
					_called.clear()
					storage.set_value("flags", {"context": body, "response": _cache})
				_finish(success)
			elif (
				_should_retry(result, status) and attempt < config.feature_flag_request_max_retries
			):
				get_tree().create_timer(0.3 * pow(2, attempt)).timeout.connect(
					func(): _fetch(generation, body, attempt + 1)
				)
			else:
				_finish(false)
	)


func _apply(response: Dictionary) -> bool:
	var quota: Variant = response.get("quotaLimited", [])
	if quota is Array and quota.has("feature_flags"):
		_cache = {}
		is_loaded = true
		return true
	if not response.get("flags") is Dictionary and not response.get("featureFlags") is Dictionary:
		return false
	for field in ["flags", "featureFlags", "featureFlagPayloads"]:
		if response.has(field) and not response[field] is Dictionary:
			return false
	var incoming := response.duplicate(true)
	var fields := ["flags", "featureFlags", "featureFlagPayloads"]
	for field in fields:
		if not incoming.has(field):
			incoming[field] = {}
	var merge: bool = response.get("errorsWhileComputingFlags") == true
	for key in incoming.flags.keys():
		var details: Variant = incoming.flags[key]
		if details is Dictionary and details.get("failed") == true:
			incoming.featureFlags.erase(key)
			incoming.featureFlagPayloads.erase(key)
			if merge and get_flag(key, false).has_value:
				incoming.flags.erase(key)
	if merge:
		# Replace each incoming pair together, retaining only untouched successful pairs.
		var keys: Dictionary = incoming.flags.duplicate()
		keys.merge(incoming.featureFlags)
		for field in fields:
			var previous: Dictionary = _cache.get(field, {}).duplicate(true)
			for key in keys:
				previous.erase(key)
			previous.merge(incoming[field], true)
			incoming[field] = previous
	_cache = incoming
	is_loaded = true
	return true


func _track(flag: PostHogFeatureFlag, details: Dictionary) -> void:
	var token := JSON.stringify([flag.key, flag.value])
	if _called.has(token):
		return
	if _called.size() >= 1000:
		_called.erase(_called.keys()[0])
	_called[token] = true
	var properties := {"$feature_flag": flag.key, "$feature_flag_response": flag.value}
	var errors: Array[String] = []
	if details.get("failed") == true and not flag.has_value:
		errors.append("evaluation_failed")
	if _cache.get("errorsWhileComputingFlags") == true:
		errors.append("errors_while_computing_flags")
	if not errors.is_empty():
		properties["$feature_flag_error"] = ",".join(errors)
	if _cache.has("requestId"):
		properties["$feature_flag_request_id"] = _cache.requestId
	if _cache.has("evaluatedAt"):
		properties["$feature_flag_evaluated_at"] = _cache.evaluatedAt
	if flag.metadata.has("id"):
		properties["$feature_flag_id"] = flag.metadata.id
	if flag.metadata.has("version"):
		properties["$feature_flag_version"] = flag.metadata.version
	if details.get("reason") is Dictionary:
		properties["$feature_flag_reason"] = details.reason.get("description", "")
	capture.call("$feature_flag_called", properties)


func _finish(success: bool) -> void:
	var generation := _generation
	loading = false
	request_finished.emit(success)
	if success and enabled and generation == _generation:
		loaded.emit()


func _should_retry(result: int, status: int) -> bool:
	return (
		status == 502
		or status == 504
		or (
			status == 0
			and (
				result
				in [
					HTTPRequest.RESULT_TIMEOUT,
					HTTPRequest.RESULT_CONNECTION_ERROR,
					HTTPRequest.RESULT_NO_RESPONSE,
					HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH
				]
			)
		)
	)
