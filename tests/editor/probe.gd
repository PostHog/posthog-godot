@tool
extends EditorPlugin


func _enter_tree() -> void:
	_report.call_deferred()


func _report() -> void:
	var result := {
		"config": ProjectSettings.get_setting("posthog/config", null),
		"autoload": ProjectSettings.get_setting("autoload/PostHog", null),
		"file_picker": false,
	}
	for property in ProjectSettings.get_property_list():
		if property.name == "posthog/config":
			result.file_picker = (
				property.type == TYPE_STRING
				and property.hint == PROPERTY_HINT_FILE
				and property.hint_string == "*.tres"
			)
	print("POSTHOG_EDITOR_TEST " + JSON.stringify(result))
