extends Node

var _command_callback: JavaScriptObject


func _ready() -> void:
	if OS.has_feature("web"):
		_command_callback = JavaScriptBridge.create_callback(_on_command)
		var window := JavaScriptBridge.get_interface("window")
		window.posthogTestCommand = _command_callback
		JavaScriptBridge.eval("window.posthogTestResults = {}; window.posthogTestReady = true;")
	else:
		PostHog.capture("export_smoke")
		_export_error()
		var success := await PostHog.flush()
		PostHog.shutdown()
		get_tree().quit(0 if success and not OS.has_feature("editor") else 1)


func _on_command(arguments: Array) -> void:
	var id := int(arguments[0])
	var command := str(arguments[1])
	var data: Dictionary = JSON.parse_string(str(arguments[2]))
	var result: Variant = await _execute(command, data)
	JavaScriptBridge.eval("window.posthogTestResults[%d] = %s;" % [id, JSON.stringify(result)])


func _execute(command: String, data: Dictionary) -> Dictionary:
	match command:
		"snapshot":
			return _snapshot()
		"capture":
			PostHog.capture(data.get("event", "browser_event"), data.get("properties", {}))
		"identify":
			await PostHog.identify(data.id)
		"register":
			PostHog.register(data.key, data.value)
		"opt_out":
			PostHog.opt_out()
		"opt_in":
			PostHog.opt_in()
		"flush":
			return {"success": await PostHog.flush()}
		"flags":
			var success := await PostHog.reload_feature_flags()
			return {
				"success": success, "value": PostHog.get_feature_flag("export-flag", false).value
			}
		"error":
			_export_error()
			return {"success": await PostHog.flush()}
		"setup":
			PostHog.shutdown()
			var config: PostHogConfig = load("res://config.tres").duplicate(true)
			config.host = data.host
			config.capture_exceptions = false
			PostHog.setup(config)
		_:
			return {"error": "Unknown command"}
	return _snapshot()


func _snapshot() -> Dictionary:
	return {
		"initialized": PostHog.is_initialized,
		"opted_out": PostHog.is_opted_out,
		"distinct_id": PostHog.distinct_id,
		"events": PostHog._queue.events.duplicate(true) if PostHog.is_initialized else [],
		"persistent": OS.is_userfs_persistent(),
		"debug": OS.is_debug_build(),
		"editor": OS.has_feature("editor")
	}


func _export_error() -> void:
	push_error("Expected export error")
