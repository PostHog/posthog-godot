extends RefCounted

const VERSION = "0.1.0"
const LIBRARY = "posthog-godot"
static var _last_ms: int = 0
static var _sequence: int = 0


static func uuid_v7() -> String:
	var milliseconds := maxi(int(Time.get_unix_time_from_system() * 1000), _last_ms)
	if milliseconds == _last_ms:
		_sequence += 1
		if _sequence > 4095:
			milliseconds += 1
			_sequence = 0
	else:
		_sequence = 0
	_last_ms = milliseconds
	var random := Crypto.new().generate_random_bytes(8)
	random[0] = (random[0] & 0x3f) | 0x80
	var tail := random.hex_encode()
	var time_hex := "%012x" % milliseconds
	return (
		"%s-%s-7%03x-%s-%s"
		% [time_hex.left(8), time_hex.substr(8), _sequence, tail.left(4), tail.substr(4)]
	)


static func timestamp() -> String:
	var now := Time.get_unix_time_from_system()
	return "%s.%03dZ" % [Time.get_datetime_string_from_unix_time(int(now)), int(now * 1000) % 1000]


static func is_json(value: Variant, depth: int = 0, allow_non_finite: bool = false) -> bool:
	if depth > 32:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME:
			return true
		TYPE_FLOAT:
			return allow_non_finite or is_finite(value)
		TYPE_ARRAY:
			for item in value:
				if not is_json(item, depth + 1, allow_non_finite):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if (
					(not key is String and not key is StringName)
					or not is_json(value[key], depth + 1, allow_non_finite)
				):
					return false
			return true
	return false


# Validate with is_json(value, 0, true) first to avoid expanding cyclic containers.
static func normalize_non_finite(value: Variant, depth: int = 0) -> Variant:
	if depth > 32:
		return value
	match typeof(value):
		TYPE_FLOAT:
			return value if is_finite(value) else null
		TYPE_ARRAY:
			var result: Array = []
			for item in value:
				result.append(normalize_non_finite(item, depth + 1))
			return result
		TYPE_DICTIONARY:
			var result: Dictionary = {}
			for key in value:
				result[key] = normalize_non_finite(value[key], depth + 1)
			return result
	return value


static func valid_event(event: Variant) -> bool:
	return (
		event is Dictionary
		and event.get("event") is String
		and not event.event.strip_edges().is_empty()
		and event.get("uuid") is String
		and not event.uuid.is_empty()
		and event.get("distinct_id") is String
		and not event.distinct_id.is_empty()
		and event.get("timestamp") is String
		and event.get("properties") is Dictionary
		and is_json(event)
	)


static func warn(message: String) -> void:
	push_warning("[PostHog] " + message)
