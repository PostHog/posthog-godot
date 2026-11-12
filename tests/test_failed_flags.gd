extends RefCounted


static func run(suite: SceneTree) -> void:
	for error_bit in [false, null, true]:
		var node: Node = suite.client()
		var network: Node = suite.mock(node)
		var response := {
			"flags":
			{
				"checkout":
				{
					"enabled": true,
					"variant": "failed-variant",
					"failed": true,
					"metadata": {"id": 123, "payload": '{"copy":"failed"}'},
					"reason": {"description": "Evaluation failed"}
				},
				"failed-false": {"enabled": false, "failed": true},
				"disabled": {"enabled": false, "failed": false},
				"healthy": {"enabled": false}
			},
			"featureFlags": {"checkout": "failed-mirror"},
			"featureFlagPayloads": {"checkout": "failed-payload"}
		}
		if error_bit != null:
			response.errorsWhileComputingFlags = error_bit
		network.responses = [{"body": JSON.stringify(response)}]
		suite.check(await node.reload_feature_flags(), "failed records response loads")
		var flag: PostHogFeatureFlag = node.get_feature_flag("checkout", false)
		suite.check(
			not flag.has_value and not flag.has_payload and not flag.metadata.has("payload"),
			"failed variant and payload omitted"
		)
		suite.check(node.queued_event_count == 0, "failed read event suppression")
		suite.check(node.is_feature_enabled("checkout", true), "failed flag honors true default")
		suite.check(node.queued_event_count == 1, "failed read emits event")
		if node.queued_event_count > 0:
			var event: Dictionary = node._queue.events.back().properties
			suite.check(
				event.get("$feature_flag_response") == null, "failed response is null, not default"
			)
			var errors: String = event.get("$feature_flag_error", "")
			suite.check(
				errors.contains("evaluation_failed") and not errors.contains("flag_missing"),
				"failed classification"
			)
			suite.check(
				errors.contains("errors_while_computing_flags") == (error_bit == true),
				"independent global error"
			)
			suite.check(event.get("$feature_flag_id") == 123, "failed diagnostic metadata retained")
		node.get_feature_flag("checkout")
		suite.check(node.queued_event_count == 1, "failed reads deduplicate")
		suite.check(
			node.is_feature_enabled("failed-false", true), "failed false cannot defeat true default"
		)
		node._config.send_feature_flag_event = false
		var count: int = node.queued_event_count
		node._flags._called.clear()
		node.get_feature_flag("checkout")
		suite.check(node.queued_event_count == count, "config suppresses failed events")
		node._config.send_feature_flag_event = true
		suite.check(not node.is_feature_enabled("disabled", true), "healthy false honors value")
		suite.check(
			not node.is_feature_enabled("healthy", true), "absent failed marker remains healthy"
		)
		suite.check(
			not node._queue.events.back().properties.get("$feature_flag_error", "").contains(
				"evaluation_failed"
			),
			"healthy sibling has no per-flag error"
		)
		await suite.dispose(node)

	for error_bit in [false, null, true]:
		var node: Node = suite.client()
		var network: Node = suite.mock(node)
		network.responses = [
			{
				"body":
				JSON.stringify(
					{
						"flags":
						{
							"checkout": {"enabled": true, "metadata": {"payload": "old"}},
							"deleted": {"enabled": true}
						}
					}
				)
			}
		]
		await node.reload_feature_flags()
		var response := {
			"flags":
			{"checkout": {"enabled": false, "failed": true}, "disabled": {"enabled": false}}
		}
		if error_bit != null:
			response.errorsWhileComputingFlags = error_bit
		network.responses = [{"body": JSON.stringify(response)}]
		await node.reload_feature_flags()
		var flag: PostHogFeatureFlag = node.get_feature_flag("checkout")
		suite.check(
			flag.has_value == (error_bit == true), "only response-wide errors retain stale success"
		)
		suite.check(
			flag.payload == ("old" if error_bit == true else null),
			"retention preserves paired payload"
		)
		suite.check(
			node.get_feature_flag("deleted", false).has_value == (error_bit == true),
			"full replacement versus errored merge"
		)
		suite.check(not node.is_feature_enabled("disabled", true), "merge updates healthy false")
		if error_bit == true:
			suite.check(
				not node._queue.events.front().properties.get("$feature_flag_error", "").contains(
					"evaluation_failed"
				),
				"retained success has no failure error"
			)
		await suite.dispose(node)
