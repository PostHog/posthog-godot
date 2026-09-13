extends RefCounted

const RuntimeEnvironment = preload("res://addons/posthog/internal/runtime_environment.gd")


class Client:
	extends "res://addons/posthog/posthog.gd"

	var environment: String = "editor_play"

	func _runtime_environment() -> String:
		return environment


static func run(suite: SceneTree) -> void:
	for sample in [
		[[true, true, false, true], "editor"],
		[[false, true, false, true], "editor_play"],
		[[false, false, true, false], "dedicated_server"],
		[[false, false, false, true], "export_debug"],
		[[false, false, false, false], "export_release"],
	]:
		suite.check(
			RuntimeEnvironment.detect.callv(sample[0]) == sample[1], "runtime environment detection"
		)
	suite.check(
		RuntimeEnvironment.detect() == "editor_play",
		"headless editor binary is not mistaken for a server export"
	)
	var previous: Variant = ProjectSettings.get_setting("posthog/config", null)
	for environment in ["editor_play", "export_debug", "export_release", "dedicated_server"]:
		var config: PostHogConfig = suite.config()
		var path := "user://posthog-auto-%s-%d.tres" % [environment, Time.get_ticks_usec()]
		suite.check(ResourceSaver.save(config, path) == OK, "auto-init config saved")
		ProjectSettings.set_setting("posthog/config", path)
		var node := Client.new()
		node.environment = environment
		suite.root.add_child(node)
		if environment == "editor_play":
			suite.check(
				not node.is_initialized, "editor play skips automatic initialization by default"
			)
			suite.check(
				node.get_child_count() == 0 and node.distinct_id.is_empty(),
				"skipped initialization creates no queue, transport, logger, or identity"
			)
			suite.check(node.setup(config), "explicit setup still works during editor play")
		else:
			suite.check(node.is_initialized, "exports still initialize automatically")
		node.capture("environment-test", {"$godot_environment": "spoofed"})
		suite.check(
			node._queue.events.back().properties.get("$godot_environment") == environment,
			"runtime metadata cannot be spoofed by event properties"
		)
		suite.check(
			node._flag_context().person_properties.get("$godot_environment") == environment,
			"default flag context contains runtime environment"
		)
		node._config.send_default_person_properties_for_flags = false
		suite.check(
			not node._flag_context().person_properties.has("$godot_environment"),
			"default flag metadata can be disabled"
		)
		await suite.dispose(node)
		DirAccess.remove_absolute(path)

	var config: PostHogConfig = suite.config()
	config.skip_auto_init_on_editor_play = false
	var path := "user://posthog-auto-enabled-%d.tres" % Time.get_ticks_usec()
	ResourceSaver.save(config, path)
	ProjectSettings.set_setting("posthog/config", path)
	var node := Client.new()
	suite.root.add_child(node)
	suite.check(node.is_initialized, "editor auto-initialization can be explicitly enabled")
	await suite.dispose(node)
	ProjectSettings.set_setting("posthog/config", previous)
	DirAccess.remove_absolute(path)
