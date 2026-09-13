@tool
extends EditorPlugin


func _enable_plugin() -> void:
	add_autoload_singleton("PostHog", "res://addons/posthog/posthog.gd")
	if not ProjectSettings.has_setting("posthog/config"):
		ProjectSettings.set_setting("posthog/config", "")
	ProjectSettings.add_property_info(
		{
			"name": "posthog/config",
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_FILE,
			"hint_string": "*.tres"
		}
	)
	ProjectSettings.set_initial_value("posthog/config", "")
	ProjectSettings.save()


func _disable_plugin() -> void:
	remove_autoload_singleton("PostHog")
