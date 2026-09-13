class_name PostHogFeatureFlag
extends RefCounted

var key: String
## A bool, a variant String, or null when the flag is unknown.
var value: Variant
var payload: Variant
var metadata: Dictionary = {}
var is_enabled: bool:
	get:
		return value == true if value is bool else value is String and not value.is_empty()
var has_value: bool:
	get:
		return value != null
var has_payload: bool:
	get:
		return payload != null


func get_variant(default_value: String = "") -> String:
	return value if value is String else default_value


func get_payload(default_value: Variant = null) -> Variant:
	var result: Variant = payload if payload != null else default_value
	return result.duplicate(true) if result is Dictionary or result is Array else result
