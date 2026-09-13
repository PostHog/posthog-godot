extends SceneTree

const SDK = preload("res://addons/posthog/posthog.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var config := PostHogConfig.new()
	config.api_key = "phc_test"
	config.host = OS.get_environment("POSTHOG_TEST_HOST")
	config.persistence = false
	config.preload_feature_flags = false
	config.capture_application_lifecycle_events = false
	var sdk := SDK.new()
	root.add_child(sdk)
	if not sdk.setup(config):
		quit(1)
		return
	sdk._logger._log_error(
		"save", "res://game.gd", 10, "quit-error", "", false, Logger.ERROR_TYPE_SCRIPT, []
	)
	sdk.quit()
