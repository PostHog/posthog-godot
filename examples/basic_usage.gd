extends Control

var _status: Label


func _ready() -> void:
	var layout := VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	add_child(layout)
	_status = Label.new()
	_status.text = "Set POSTHOG_API_KEY to enable the example. No events are sent without it."
	layout.add_child(_status)
	_add_button(
		layout,
		"Capture level completed",
		func(): PostHog.capture("level_completed", {"level": 1, "score": 9001})
	)
	_add_button(
		layout,
		"Identify player",
		func():
			await PostHog.identify("example-player", {"plan": "free"}, {"first_game": "demo"})
			_status.text = "Identified as " + PostHog.distinct_id
	)
	_add_button(
		layout,
		"Check feature flag",
		func():
			await PostHog.reload_feature_flags()
			var flag := PostHog.get_feature_flag("new-game-mode")
			_status.text = "new-game-mode: %s, payload: %s" % [flag.value, flag.get_payload()]
	)
	_add_button(
		layout,
		"Capture handled error",
		func(): PostHog.capture_exception("Example inventory error")
	)
	_add_button(layout, "Reset player", func(): await PostHog.reset())
	_add_button(layout, "Opt out", func(): PostHog.opt_out())
	_add_button(layout, "Opt in", func(): PostHog.opt_in())
	_add_button(
		layout, "Flush", func(): _status.text = "Flush successful: %s" % await PostHog.flush()
	)
	var api_key := OS.get_environment("POSTHOG_API_KEY")
	if api_key.is_empty():
		return
	var config := PostHogConfig.new()
	config.api_key = api_key
	var host := OS.get_environment("POSTHOG_HOST")
	if not host.is_empty():
		config.host = host
	if PostHog.setup(config):
		PostHog.register("example", true)
		PostHog.screen("Main Menu")
		_status.text = "PostHog initialized"


func _add_button(parent: Node, label: String, action: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.pressed.connect(action)
	parent.add_child(button)
