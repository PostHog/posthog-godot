extends Control

var checks: Array = []
var failures: Array = []
var wire: Array = []
var observed: Array = []
var dropped: Array = []
var state: Dictionary = {}
var label: Label
var phase: int = 0
@onready var run_id: String = ProjectSettings.get_setting("mobile_smoke/run_id", "local-smoke")


func _ready() -> void:
	label = Label.new()
	label.position = Vector2(24, 100)
	label.size = Vector2(672, 1050)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 28)
	add_child(label)
	label.text = "PostHog mobile smoke test\n" + OS.get_name() + "\n" + run_id + "\n\nRunning..."
	if FileAccess.file_exists("user://smoke-state.json"):
		state = JSON.parse_string(FileAccess.get_file_as_string("user://smoke-state.json"))
	phase = int(state.get("phase", 0))
	_check(PostHog.is_initialized, "resource autoload initialized")
	if not PostHog.is_initialized:
		_finish("initialization_failed")
		return
	PostHog._config.before_send = _observe_event
	PostHog._transport.child_entered_tree.connect(_observe_request)
	PostHog.events_dropped.connect(_on_events_dropped)
	_check(PostHog._runtime_environment() == "export_release", "actual release runtime")
	match phase:
		0:
			await _test_initial_delivery()
		1:
			await _test_queue_and_opt_out()
		2:
			await _test_persisted_opt_out()
		3:
			_check(not PostHog.is_opted_out, "opt-in persisted across restart")
			_check(PostHog.distinct_id == state.distinct_id, "identity still persisted")
			_check(
				PostHog.queued_event_count == 0 and wire.is_empty(),
				"no acknowledged or discarded events replayed"
			)
			state["phase"] = 4
			_finish("complete")
		_:
			_finish("already_complete")


func _test_initial_delivery() -> void:
	PostHog.register("sdk_test", true)
	PostHog.register("test_run_id", run_id)
	PostHog.register("test_platform", OS.get_name())
	state["anonymous_id"] = PostHog.distinct_id
	_check(PostHog.distinct_id.length() == 36, "anonymous UUID initialized")
	_check(PostHog.session_id.length() == 36, "session UUID initialized")
	PostHog.capture("godot_sdk_mobile_smoke", {"stage": "anonymous", "unicode": "🦔"})
	var identified: String = "godot-sdk-smoke-" + OS.get_name() + "-" + run_id
	_check(
		await PostHog.identify(identified, {"sdk_test": true, "test_run_id": run_id}),
		"synthetic identify accepted"
	)
	_check(PostHog.distinct_id == identified, "identity updated")
	PostHog.screen("Godot SDK synthetic mobile test")
	var flags_ok: bool = await PostHog.reload_feature_flags()
	_check(flags_ok and PostHog.feature_flags_are_loaded, "live feature flags loaded")
	_expected_error()
	_check(await PostHog.flush(), "cloud initial batch HTTP-acknowledged")
	_check(PostHog.queued_event_count == 0, "acknowledged events removed")
	var errors: Array = observed.filter(_is_exception)
	_check(errors.size() == 1, "one automatic error captured")
	if errors.size() == 1:
		var frames: Array = errors[0].properties["$exception_list"][0].get("stacktrace", {}).get(
			"frames", []
		)
		_check(frames.any(_is_test_frame), "release error has GDScript stack frames")
		_check(frames.all(_is_custom_frame), "error frames satisfy backend custom-frame schema")
	_check(observed.all(_has_test_metadata), "runtime and test metadata attached")
	PostHog.capture("godot_sdk_mobile_smoke", {"stage": "persisted_queue"})
	_check(PostHog.queued_event_count == 1, "unsent event queued for restart")
	state["distinct_id"] = PostHog.distinct_id
	if PostHog.queued_event_count == 1:
		state["event_uuid"] = PostHog._queue.events[0].uuid
	state["phase"] = 1
	_finish("restart_to_verify_queue")


func _test_queue_and_opt_out() -> void:
	_check(PostHog.distinct_id == state.distinct_id, "identity persisted across restart")
	_check(PostHog._super_properties.get("test_run_id") == run_id, "super properties persisted")
	_check(PostHog.queued_event_count == 1, "unsent queue persisted")
	if PostHog.queued_event_count == 1:
		_check(
			PostHog._queue.events[0].uuid == state.get("event_uuid"), "durable event UUID unchanged"
		)
	_check(await PostHog.flush(), "persisted batch HTTP-acknowledged")
	_check(PostHog.queued_event_count == 0, "persisted queue drained")
	PostHog.capture("godot_sdk_mobile_smoke", {"stage": "must_not_send_discarded"})
	PostHog.opt_out()
	_check(
		PostHog.is_opted_out and PostHog.queued_event_count == 0, "opt-out discarded queued event"
	)
	var requests_before: int = wire.size()
	PostHog.capture("godot_sdk_mobile_smoke", {"stage": "must_not_send_opted_out"})
	_check(not await PostHog.reload_feature_flags(), "opt-out blocked flag request")
	_check(not await PostHog.flush(), "opt-out blocked flush")
	_check(
		PostHog.queued_event_count == 0 and wire.size() == requests_before,
		"no opted-out event or network request"
	)
	state["phase"] = 2
	_finish("restart_to_verify_opt_out")


func _test_persisted_opt_out() -> void:
	_check(PostHog.is_opted_out, "opt-out persisted across restart")
	_check(PostHog.distinct_id == state.distinct_id, "identity retained with consent disabled")
	PostHog.capture("godot_sdk_mobile_smoke", {"stage": "must_not_send_after_restart"})
	_check(
		PostHog.queued_event_count == 0 and wire.is_empty(),
		"restart did not restore discarded events or send while opted out"
	)
	PostHog.opt_in()
	_check(not PostHog.is_opted_out, "opt-in enabled capture")
	PostHog.capture("godot_sdk_mobile_smoke", {"stage": "opt_in"})
	_check(await PostHog.flush(), "opt-in batch HTTP-acknowledged")
	_check(PostHog.queued_event_count == 0, "opt-in queue drained")
	state["phase"] = 3
	_finish("restart_to_verify_opt_in")


func _observe_event(event: Dictionary) -> Dictionary:
	observed.append(event.duplicate(true))
	print("SMOKE_EVENT " + JSON.stringify({"event": event.event, "uuid": event.uuid}))
	return event


func _observe_request(node: Node) -> void:
	if node is HTTPRequest:
		node.request_completed.connect(_on_response)


func _on_response(
	result: int, status: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	wire.append({"result": result, "status": status, "response_bytes": body.size()})
	print("SMOKE_HTTP " + JSON.stringify(wire.back()))


func _on_events_dropped(count: int, reason: String) -> void:
	dropped.append({"count": count, "reason": reason})


func _expected_error() -> void:
	push_error("PostHog SDK synthetic mobile smoke error: " + OS.get_name() + " " + run_id)


func _is_exception(event: Dictionary) -> bool:
	return event.event == "$exception"


func _is_test_frame(frame: Dictionary) -> bool:
	return (
		str(frame.get("filename", "")).ends_with("main.gd")
		and frame.get("function") == "_expected_error"
		and int(frame.get("lineno", 0)) > 0
	)


func _is_custom_frame(frame: Dictionary) -> bool:
	return (
		frame.get("platform") == "custom"
		and frame.get("lang") == "godot"
		and frame.get("resolved") == true
	)


func _has_test_metadata(event: Dictionary) -> bool:
	return (
		event.properties.get("$godot_environment") == "export_release"
		and event.properties.get("test_run_id") == run_id
	)


func _http_succeeded(response: Dictionary) -> bool:
	return (
		response.result == HTTPRequest.RESULT_SUCCESS
		and response.status >= 200
		and response.status < 300
	)


func _check(condition: bool, name: String) -> void:
	checks.append({"name": name, "passed": condition})
	if not condition:
		failures.append(name)
	print("SMOKE_CHECK " + JSON.stringify(checks.back()))


func _finish(status: String) -> void:
	_check(dropped.is_empty(), "no ingestion rejections or dropped events")
	_check(wire.all(_http_succeeded), "all completed HTTPS requests succeeded")
	var prior_failures: Array = state.get("failures", [])
	prior_failures.append_array(failures)
	state["failures"] = prior_failures
	_write_json("user://smoke-state.json", state)
	var report := {
		"run_id": run_id,
		"platform": OS.get_name(),
		"phase": phase,
		"status": status,
		"checks": checks,
		"failures": prior_failures,
		"http": wire,
		"events": observed,
		"user_data_dir": OS.get_user_data_dir()
	}
	_write_json("user://smoke-report-%d.json" % phase, report)
	label.text = (
		"PostHog mobile smoke test\n"
		+ OS.get_name()
		+ " release export\n\n"
		+ ("PASS" if prior_failures.is_empty() else "FAIL")
		+ " — "
		+ status
		+ "\n\n"
		+ str(checks.size())
		+ " checks this launch\n"
		+ str(wire.size())
		+ " HTTP responses\n\n"
		+ run_id
	)
	# Stop background flushing so the queued-event test survives the next app restart.
	PostHog.shutdown()
	print(
		(
			"SMOKE_REPORT "
			+ JSON.stringify(
				{
					"run_id": run_id,
					"platform": OS.get_name(),
					"phase": phase,
					"status": status,
					"passed": prior_failures.is_empty(),
					"check_count": checks.size(),
					"failures": prior_failures
				}
			)
		)
	)


func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value, "\t"))
	file.close()
