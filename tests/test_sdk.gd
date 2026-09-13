extends SceneTree

const SDK = preload("res://addons/posthog/posthog.gd")
const Config = preload("res://addons/posthog/posthog_config.gd")
const Utils = preload("res://addons/posthog/internal/utils.gd")
const Session = preload("res://addons/posthog/internal/session.gd")
const MockTransport = preload("mock_transport.gd")
var checks: int = 0
var failures: int = 0
var _test_path := "user://posthog-tests-" + str(Time.get_ticks_usec())


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_config_and_uuid()
	await _test_capture_and_identity()
	await _test_profiles_and_consent()
	await _test_before_send()
	await _test_reinitialize()
	_test_sessions()
	await _test_persistence()
	await _test_cached_flags_and_corruption()
	await _test_queue()
	await _test_flags()
	await _test_flag_races()
	await _test_lifecycle_and_errors()
	await _test_http()
	_remove_directory(_test_path)
	print("PostHog tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + description)


func config() -> PostHogConfig:
	var value := Config.new()
	value.api_key = "phc_test"
	value.host = "http://127.0.0.1:1"
	value.persistence = false
	value.preload_feature_flags = false
	value.capture_application_lifecycle_events = false
	value.capture_exceptions = false
	value.flush_at = 1000
	value.flush_on_quit = false
	return value


func client(settings: PostHogConfig = null) -> Node:
	var node := SDK.new()
	root.add_child(node)
	check(node.setup(settings if settings != null else config()), "setup succeeds")
	return node


func mock(node: Node) -> Node:
	var network := MockTransport.new()
	node.add_child(network)
	node._queue.transport = network
	node._flags.transport = network
	return network


func dispose(node: Node) -> void:
	node.shutdown()
	node.queue_free()
	await process_frame


func _test_config_and_uuid() -> void:
	var settings := Config.new()
	check(not settings.validation_error().is_empty(), "API key required")
	settings.api_key = "phc_test"
	check(settings.validation_error().is_empty(), "defaults valid")
	settings.max_queue_size = 0
	check(not settings.validation_error().is_empty(), "zero queue rejected")
	settings.max_queue_size = 1
	settings.host = "file:///etc/passwd"
	check(not settings.validation_error().is_empty(), "non-HTTP host rejected")
	settings.host = "https://example.com/?secret=1"
	check(not settings.validation_error().is_empty(), "host query rejected")
	var previous := ""
	var unique: Dictionary = {}
	for index in 5000:
		var id := Utils.uuid_v7()
		check(
			id.length() == 36 and id[14] == "7" and id[19] in ["8", "9", "a", "b"],
			"UUIDv7 wire format"
		)
		check(id > previous and not unique.has(id), "UUIDs unique and ordered")
		unique[id] = true
		previous = id
	check(Utils.timestamp().ends_with("Z"), "UTC timestamp")
	check(
		not Utils.is_json({"bad": NAN}) and not Utils.is_json(Vector2.ONE),
		"non-JSON values rejected"
	)
	var cyclic: Array = []
	cyclic.append(cyclic)
	check(not Utils.is_json(cyclic), "cycles rejected without recursion overflow")
	cyclic.clear()


func _test_capture_and_identity() -> void:
	var node := client()
	var anonymous: String = node.distinct_id
	var properties := {"score": 42, "nested": {"level": 1}}
	node.register("build", "test")
	node.register("score", 0)
	node.capture("level_completed", properties)
	properties.nested.level = 9
	var event: Dictionary = node._queue.events.back()
	check(
		event.event == "level_completed" and event.distinct_id == anonymous,
		"anonymous event envelope"
	)
	check(
		event.properties.score == 42 and event.properties.build == "test",
		"event properties override super properties"
	)
	check(event.properties.nested.level == 1, "event immutable after capture")
	check(event.properties["$lib"] == "posthog-godot", "Godot library metadata")
	check(
		not event.properties["$process_person_profile"],
		"anonymous profile not processed by default"
	)
	check(event.properties.has("$session_id"), "session enriched")
	node.screen("Menu", {"$screen_name": "wrong"})
	check(node._queue.events.back().properties["$screen_name"] == "Menu", "screen event")
	await node.identify("player-1", {"plan": "paid"}, {"plan": "free", "first": true})
	event = node._queue.events.back()
	check(
		event.event == "$identify" and event.distinct_id == "player-1",
		"identify event uses new identity"
	)
	check(event.properties["$anon_distinct_id"] == anonymous, "anonymous identity linked")
	check(
		event.properties["$set"].plan == "paid" and event.properties["$set_once"].first,
		"person set/set_once"
	)
	check(event.properties["$process_person_profile"], "identified profile processed")
	check(node._person_properties.plan == "paid", "set wins over set_once for flag evaluation")
	await node.identify("player-1", {}, {"plan": "other"})
	check(
		not node._queue.events.back().properties.has("$anon_distinct_id"),
		"repeated identify does not merge anonymous twice"
	)
	check(node._person_properties.plan == "paid", "set_once does not overwrite cached properties")
	var nested := {"preferences": {"difficulty": "hard"}}
	await node.identify("player-1", nested)
	nested.preferences.difficulty = "easy"
	check(
		node._person_properties.preferences.difficulty == "hard",
		"identify copies nested evaluation properties"
	)
	node.alias("legacy-player")
	check(node._queue.events.back().properties.alias == "legacy-player", "alias event")
	node.group("guild", "guild-1", {"rank": 2})
	check(node._queue.events.back().event == "$groupidentify", "group identify")
	node.capture("joined")
	check(
		node._queue.events.back().properties["$groups"].guild == "guild-1", "group event enrichment"
	)
	node.group("guild", "guild-2")
	check(node._group_properties.guild.is_empty(), "switch group clears previous group properties")
	var old_session: String = node.session_id
	await node.reset()
	check(
		node.distinct_id != anonymous and node.distinct_id != "player-1",
		"reset rotates anonymous identity"
	)
	check(node.session_id != old_session, "reset rotates session")
	check(
		node._identity.groups.is_empty() and node._super_properties.is_empty(),
		"reset clears groups and super properties"
	)
	check(
		node._person_properties.is_empty() and node._group_properties.is_empty(),
		"reset clears flag overrides"
	)
	check(node._queue.events[0].distinct_id == anonymous, "reset does not rewrite queued events")
	await dispose(node)


func _test_profiles_and_consent() -> void:
	var settings := config()
	settings.person_profiles = Config.PersonProfiles.NEVER
	var node := client(settings)
	var id: String = node.distinct_id
	check(not await node.identify("not-allowed"), "never mode blocks identify")
	node.alias("not-allowed")
	node.capture("anonymous", {"$process_person_profile": true})
	check(
		node.distinct_id == id and node.queued_event_count == 1,
		"never mode has no identity side effects"
	)
	check(
		not node._queue.events.back().properties["$process_person_profile"],
		"never cannot be overridden in event props"
	)
	node.opt_out()
	node.capture("ignored")
	await node.identify("ignored")
	node.group("guild", "ignored")
	node.register("ignored", true)
	check(
		(
			node.queued_event_count == 0
			and node.distinct_id == id
			and node._identity.groups.is_empty()
		),
		"opt out drops and blocks capture and identity mutation"
	)
	check(
		not await node.reload_feature_flags() and not await node.flush(),
		"opt out blocks network operations"
	)
	node.opt_in()
	node.capture("allowed")
	check(node.queued_event_count == 1, "opt in resumes queue")
	await dispose(node)
	settings = config()
	settings.person_profiles = Config.PersonProfiles.ALWAYS
	settings.reuse_anonymous_id = true
	node = client(settings)
	id = node.distinct_id
	node.capture("anonymous")
	check(
		node._queue.events.back().properties["$process_person_profile"],
		"always mode processes anonymous profiles"
	)
	await node.identify("known")
	await node.reset()
	check(node.distinct_id == id, "reuse anonymous ID option")
	await dispose(node)


func _test_before_send() -> void:
	var settings := config()
	settings.before_send = func(event: Dictionary):
		if event.event == "drop":
			return null
		event.properties.erase("email")
		event.properties.scrubbed = true
		event.uuid = "../../invalid"
		return event
	var node := client(settings)
	node.capture("drop")
	node.capture("send", {"email": "private@example.com"})
	check(node.queued_event_count == 1, "before_send drops event")
	var event: Dictionary = node._queue.events.back()
	check(
		not event.properties.has("email") and event.properties.scrubbed,
		"before_send redacts enriched event"
	)
	check(event.uuid.length() == 36, "before_send cannot change durable queue UUID")
	node._config.before_send = func(_event: Dictionary): return {"bad": true}
	node.capture("invalid")
	check(node.queued_event_count == 1, "malformed before_send return dropped")
	node._config.before_send = func(value: Dictionary):
		node.capture("recursive")
		return value
	node.capture("outer")
	check(node.queued_event_count == 2, "recursive capture from before_send blocked")
	node._config.before_send = func(value: Dictionary):
		node.opt_out()
		return value
	node.capture("consent_changed")
	check(node.queued_event_count == 0, "consent rechecked after before_send")
	await dispose(node)


func _test_reinitialize() -> void:
	var settings := config()
	settings.preload_feature_flags = true
	var node := client(settings)
	node.shutdown()
	check(node.setup(config()), "same node can be reinitialized")
	var network := mock(node)
	await process_frame
	await process_frame
	check(network.calls.is_empty(), "old deferred preload must not run against new config")
	await dispose(node)


func _test_sessions() -> void:
	var session := Session.new()
	var id: String = session.get_id(0)
	check(id == session.get_id(100), "session stable")
	check(id != session.get_id(Session.TIMEOUT_MS + 1), "inactivity rotates session")
	id = session.id
	session.set_foreground(false, Session.TIMEOUT_MS + 2)
	check(
		session.get_id(2 * Session.TIMEOUT_MS + 3).is_empty(),
		"expired background session not recreated"
	)
	session.set_foreground(true, 2 * Session.TIMEOUT_MS + 4)
	check(not session.id.is_empty() and session.id != id, "foreground starts fresh session")
	id = session.id
	session.last_activity = Session.MAX_LENGTH_MS
	check(
		session.get_id(session.started_at + Session.MAX_LENGTH_MS + 1) != id,
		"24 hour maximum session"
	)


func _test_persistence() -> void:
	var settings := config()
	settings.persistence = true
	settings.storage_path = _test_path
	var node := client(settings)
	await node.identify("persistent-player")
	node.group("guild", "persistent-guild")
	node.register("persisted", 5)
	node.capture("persisted-event")
	var event_id: String = node._queue.events.back().uuid
	await dispose(node)
	node = client(settings)
	check(node.distinct_id == "persistent-player", "identity restored")
	check(
		node._identity.groups.guild == "persistent-guild" and node._super_properties.persisted == 5,
		"groups and super properties restored"
	)
	check(node._queue.events.back().uuid == event_id, "unsent event restored with original UUID")
	node.opt_out()
	await dispose(node)
	node = client(settings)
	check(
		node.is_opted_out and node.queued_event_count == 0, "opt out persists and clears disk queue"
	)
	check(node._flags._cache.is_empty(), "opt out clears flag cache")
	await dispose(node)
	settings.api_key = "phc_other"
	node = client(settings)
	check(
		not node.is_opted_out and node.distinct_id != "persistent-player",
		"projects have isolated storage"
	)
	await dispose(node)


func _test_cached_flags_and_corruption() -> void:
	var settings := config()
	settings.persistence = true
	settings.storage_path = _test_path + "-cache"
	var node := client(settings)
	var network := mock(node)
	network.responses = [{"body": _flag_response()}]
	await node.reload_feature_flags()
	await dispose(node)
	node = client(settings)
	check(
		(
			node.feature_flags_are_loaded
			and node.get_feature_flag("experiment", false).value == "test"
		),
		"flags immediately restored from disk"
	)
	await node.identify("different-player")
	check(not node.feature_flags_are_loaded, "identity clears persisted cached flags")
	await dispose(node)
	node = client(settings)
	check(
		not node.get_feature_flag("experiment").has_value,
		"previous identity flags unavailable after restart"
	)
	node._storage.set_value(
		"identity",
		{
			"anonymous_id": "valid",
			"distinct_id": "valid",
			"identified": "bad",
			"groups": {"bad": []}
		}
	)
	node._storage.set_value("group_properties", {"bad": "not a dictionary"})
	node._storage.set_value("flags", {"context": "corrupt"})
	await dispose(node)
	node = client(settings)
	check(
		not node._identity.identified and node._identity.groups.is_empty(),
		"malformed persisted identity fields discarded"
	)
	check(node._group_properties.is_empty(), "malformed group properties discarded")
	node._storage.set_value("opted_out", "corrupt")
	await dispose(node)
	node = client(settings)
	check(node.is_opted_out, "corrupt consent fails closed")
	var directory: String = node._storage._directory
	await dispose(node)
	var file := FileAccess.open(directory.path_join("state.json"), FileAccess.WRITE)
	file.store_string("not JSON")
	file.close()
	node = client(settings)
	check(not node.distinct_id.is_empty(), "corrupt state does not prevent initialization")
	await dispose(node)
	_remove_directory(settings.storage_path)


func _test_queue() -> void:
	var settings := config()
	settings.max_batch_size = 2
	var node := client(settings)
	var network := mock(node)
	for index in 5:
		node.capture("batch-%d" % index)
	check(await node.flush(), "flush all batches succeeds")
	check(
		network.calls.size() == 3 and network.calls[0].body.batch.size() == 2, "batch size enforced"
	)
	check(node.queued_event_count == 0, "successful events removed")
	check(
		network.calls[0].body.api_key == "phc_test" and network.calls[0].body.has("sent_at"),
		"batch envelope"
	)
	node.capture("retry-me")
	var id: String = node._queue.events.back().uuid
	network.responses = [{"status": 503}]
	check(not await node.flush() and node.queued_event_count == 1, "5xx retains events")
	var attempts: int = network.calls.size()
	check(not await node.flush() and network.calls.size() == attempts, "backoff gates manual flush")
	node._queue._retry_at = 0
	check(await node.flush(), "retry succeeds")
	check(network.calls.back().body.batch[0].uuid == id, "retry preserves event UUID")
	node.capture("rate-limited")
	network.responses = [{"status": 429, "headers": ["Retry-After: 60"]}]
	check(not await node.flush() and node.queued_event_count == 1, "429 retains events")
	check(node._queue._retry_at - Time.get_ticks_msec() > 59000, "Retry-After honored")
	node._queue._retry_at = 0
	network.responses = [{"status": 400}]
	check(not await node.flush() and node.queued_event_count == 0, "permanent 4xx discarded")
	for index in 3:
		node.capture("split-%d" % index)
	network.responses = [{"status": 413}, {"status": 413}, {"status": 200}, {"status": 200}]
	check(
		await node.flush() and node.queued_event_count == 0,
		"413 splits and discards individually oversized event"
	)
	await dispose(node)
	settings = config()
	settings.max_queue_size = 2
	node = client(settings)
	network = mock(node)
	network.hold = true
	node.capture("oldest")
	node.capture("in-flight")
	node.flush()
	await process_frame
	node.capture("new")
	check(node._queue.events[0].event == "in-flight", "overflow evicts oldest event")
	network.complete_next()
	await process_frame
	check(
		node.queued_event_count == 1 and node._queue.events[0].event == "new",
		"in-flight ack does not delete newer captures"
	)
	node.opt_out()
	check(network.pending.is_empty(), "opt out cancels in-flight batch")
	node.opt_in()
	node.capture("after-opt-in")
	network.hold = false
	check(await node.flush(), "queue usable after cancel and opt in")
	node.capture("one")
	node.capture("two")
	node.events_dropped.connect(func(_count: int, _reason: String): node.opt_out())
	node.capture("overflows")
	check(
		node.queued_event_count == 0 and node.is_opted_out,
		"opt out from overflow signal does not persist the new event"
	)
	await dispose(node)


func _flag_response(value: Variant = "test") -> String:
	return JSON.stringify(
		{
			"flags":
			{
				"experiment":
				{
					"enabled": value if value is bool else true,
					"variant": value if value is String else null,
					"metadata": {"id": 123, "version": 4, "payload": '{"reward": 20}'},
					"reason": {"description": "Matched"}
				}
			},
			"requestId": "request-123",
			"evaluatedAt": 1700000000
		}
	)


func _test_flags() -> void:
	var node := client()
	var network := mock(node)
	check(
		not node.get_feature_flag("unknown").has_value and node.is_feature_enabled("unknown", true),
		"unknown flag and default"
	)
	check(node.queued_event_count == 0, "unknown flags do not send exposure events")
	network.responses = [{"body": _flag_response()}]
	check(await node.reload_feature_flags(), "v2 flags load")
	var flag: PostHogFeatureFlag = node.get_feature_flag("experiment")
	check(flag.is_enabled and flag.get_variant() == "test", "variant flag")
	check(flag.get_payload().reward == 20, "JSON payload deserialized")
	var payload: Dictionary = flag.get_payload()
	payload.reward = 99
	check(node.get_feature_flag_payload("experiment").reward == 20, "payloads defensively copied")
	check(node.queued_event_count == 1, "feature flag exposure deduplicated")
	var exposure: Dictionary = node._queue.events.back().properties
	check(
		exposure["$feature_flag_id"] == 123 and exposure["$feature_flag_version"] == 4,
		"exposure flag metadata"
	)
	check(
		(
			exposure["$feature_flag_request_id"] == "request-123"
			and exposure["$feature_flag_reason"] == "Matched"
		),
		"exposure evaluation metadata"
	)
	network.responses = [{"body": _flag_response(false)}]
	await node.reload_feature_flags()
	check(not node.is_feature_enabled("experiment", true), "disabled flags do not use default")
	check(node.queued_event_count == 2, "successful reload resets call tracking")
	network.responses = [{"status": 502}, {"body": _flag_response()}]
	var calls: int = network.calls.size()
	check(
		await node.reload_feature_flags() and network.calls.size() == calls + 2,
		"flags retry transient 502"
	)
	network.responses = [{"status": 429}]
	calls = network.calls.size()
	check(
		not await node.reload_feature_flags() and network.calls.size() == calls + 1,
		"flags do not retry quota/rate errors"
	)
	check(
		node.get_feature_flag("experiment", false).value == "test",
		"failed reload retains cached values"
	)
	network.responses = [{"body": "not json"}]
	check(
		not await node.reload_feature_flags() and node.feature_flags_are_loaded,
		"malformed response retains valid cache"
	)
	network.responses = [
		{
			"body":
			JSON.stringify(
				{"featureFlags": {"legacy": true}, "featureFlagPayloads": {"legacy": "[1,2]"}}
			)
		}
	]
	check(
		await node.reload_feature_flags() and node.is_feature_enabled("legacy"),
		"legacy response supported"
	)
	check(node.get_feature_flag_payload("legacy") == [1.0, 2.0], "legacy payload supported")
	check(
		not node.get_feature_flag("experiment").has_value, "successful reload removes deleted flags"
	)
	network.responses = [{"body": '{"quotaLimited":["feature_flags"]}'}]
	check(
		await node.reload_feature_flags() and not node.get_feature_flag("legacy").has_value,
		"quota clears flags"
	)
	node.set_person_properties_for_flags({"plan": "pro"}, false)
	node.set_group_properties_for_flags("guild", {"size": 10}, false)
	var context: Dictionary = node._flag_context()
	check(
		context.person_properties.plan == "pro" and context.group_properties.guild.size == 10,
		"flag overrides included"
	)
	check(
		context.person_properties.has("$os_name") and context.has("$anon_distinct_id"),
		"default flag context"
	)
	node.reset_person_properties_for_flags(false)
	node.reset_group_properties_for_flags("guild", false)
	check(
		node._person_properties.is_empty() and node._group_properties.is_empty(),
		"flag overrides reset"
	)
	await dispose(node)


func _test_flag_races() -> void:
	var node := client()
	var network := mock(node)
	network.hold = true
	node.reload_feature_flags()
	await process_frame
	check(network.pending.size() == 1, "initial flag request in flight")
	var stale_callback: Callable = network.pending[0].callback
	node.reload_feature_flags()
	await process_frame
	check(
		network.pending.size() == 1 and network.calls.size() == 1,
		"concurrent flag requests coalesced"
	)
	await node.identify("new-player")
	check(
		network.pending.is_empty() and not node._flags.loading,
		"identity cancels stale flag request"
	)
	stale_callback.call(
		HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _flag_response("stale")
	)
	check(
		not node.get_feature_flag("experiment", false).has_value,
		"late canceled response cannot restore stale flags"
	)
	network.responses = [{"body": _flag_response("new-player-variant")}]
	network.hold = false
	await node.reload_feature_flags()
	check(
		network.calls.back().body.distinct_id == "new-player", "new flag request uses new identity"
	)
	check(
		node.get_feature_flag("experiment", false).value == "new-player-variant",
		"new identity flags applied"
	)
	network.hold = true
	node.reload_feature_flags()
	await process_frame
	node.opt_out()
	check(
		network.pending.is_empty() and not node._flags.loading,
		"opt out cancels flags and releases waiters"
	)
	check(not node.get_feature_flag("experiment").has_value, "opt out removes cached flags")
	await dispose(node)


func _test_lifecycle_and_errors() -> void:
	var settings := config()
	settings.capture_application_lifecycle_events = true
	settings.capture_exceptions = true
	var node := client(settings)
	var network := mock(node)
	network.hold = true
	check(
		(
			node._queue.events[0].event == "Application Installed"
			and node._queue.events[1].event == "Application Opened"
		),
		"startup lifecycle"
	)
	node._set_backgrounded(true)
	node._set_backgrounded(true)
	check(node.queued_event_count == 3, "duplicate background notifications deduplicated")
	node._set_backgrounded(false)
	check(node._queue.events.back().properties.from_background, "foreground lifecycle event")
	node.capture_exception(
		"inventory failed",
		{"level": 2},
		"InventoryError",
		[
			{"source": "res://inventory.gd", "function": "add", "line": 12},
			{"source": "res://main.gd", "function": "start", "line": 5}
		]
	)
	var event: Dictionary = node._queue.events.back()
	check(
		event.event == "$exception" and event.properties["$exception_handled"],
		"manual handled error"
	)
	var frames: Array = event.properties["$exception_list"][0].stacktrace.frames
	check(
		frames[0].filename == "res://main.gd" and frames[1].lineno == 12,
		"stack frames oldest first"
	)
	push_error("Expected PostHog automatic error capture test")
	await process_frame
	await process_frame
	check(
		(
			node._queue.events.back().properties.get("$exception_message")
			== "Expected PostHog automatic error capture test"
		),
		"Logger captures engine errors"
	)
	check(
		not node._queue.events.back().properties["$exception_handled"],
		"automatic error marked unhandled"
	)
	var count: int = node.queued_event_count
	push_error("Expected debounced PostHog error")
	await process_frame
	check(node.queued_event_count == count, "automatic errors debounced")
	node.opt_out()
	check(node._logger == null, "logger removed on opt out")
	await dispose(node)


func _test_http() -> void:
	var host := OS.get_environment("POSTHOG_TEST_HOST")
	if host.is_empty():
		check(false, "run tests through scripts/test.py to start local HTTP fixture")
		return
	var settings := config()
	settings.host = host
	var node := client(settings)
	node.capture("http-integration", {"unicode": "Hedgehog 🦔", "nested": {"enabled": true}})
	check(await node.flush() and node.queued_event_count == 0, "real HTTP batch delivery")
	check(await node.reload_feature_flags(), "real HTTP flags request")
	check(
		node.get_feature_flag("http-flag", false).get_payload().transport == "http",
		"real HTTP flag payload"
	)
	await dispose(node)


func _remove_directory(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for subdirectory in directory.get_directories():
		_remove_directory(path.path_join(subdirectory))
	DirAccess.remove_absolute(path)
