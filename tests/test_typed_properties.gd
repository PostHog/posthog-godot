extends RefCounted


static func run(suite: SceneTree) -> void:
	var tags: Array[String] = ["original"]
	var scores: Array[float] = [1.5, 2.5]
	var ratings: Dictionary[String, float] = {"score": 1.5}
	var items: Array[Dictionary] = [{"number": NAN}]
	var nested: Dictionary[String, Array] = {"items": [INF]}
	var non_finite: Dictionary[String, float] = {"nan": NAN, "inf": INF, "negative": -INF}
	var settings: PostHogConfig = suite.config()
	settings.before_send = func(event: Dictionary):
		suite.check(
			event.properties.tags.is_same_typed(tags), "before_send preserves Array[String]"
		)
		suite.check(
			event.properties.scores.is_same_typed(scores),
			"before_send preserves finite Array[float]"
		)
		suite.check(
			event.properties.ratings.is_same_typed(ratings),
			"before_send preserves finite typed dictionary"
		)
		suite.check(
			event.properties.items.is_same_typed(items),
			"before_send preserves typed array around normalized children"
		)
		suite.check(
			event.properties.nested.is_same_typed(nested),
			"before_send preserves typed dictionary around normalized children"
		)
		suite.check(event.properties.items[0].number == null, "typed array children normalized")
		suite.check(
			event.properties.nested.items[0] == null, "typed dictionary children normalized"
		)
		suite.check(
			event.properties.non_finite == {"nan": null, "inf": null, "negative": null},
			"typed float dictionary supports null replacements"
		)
		if event.properties.tags.is_same_typed(tags):
			var callback_tags: Array[String] = event.properties.tags
			callback_tags[0] = "scrubbed"
		if event.properties.ratings.is_same_typed(ratings):
			var callback_ratings: Dictionary[String, float] = event.properties.ratings
			callback_ratings.score = 2.5
		event.properties.items[0].number = 42
		event.properties.nested.items[0] = 42
		event.properties.hook_non_finite = non_finite
		return event
	var node: Node = suite.client(settings)
	node.capture(
		"typed-properties",
		{
			"tags": tags,
			"scores": scores,
			"ratings": ratings,
			"items": items,
			"nested": nested,
			"non_finite": non_finite
		}
	)
	suite.check(node.queued_event_count == 1, "typed properties event queued")
	if node.queued_event_count == 1:
		var properties: Dictionary = node._queue.events.back().properties
		suite.check(
			properties.tags.is_same_typed(tags) and properties.tags == ["scrubbed"],
			"queued array retains type and callback edits"
		)
		suite.check(
			properties.scores.is_same_typed(scores), "queued finite float array retains type"
		)
		suite.check(
			properties.ratings.is_same_typed(ratings) and properties.ratings.score == 2.5,
			"queued dictionary retains type and callback edits"
		)
		suite.check(
			properties.items.is_same_typed(items) and properties.nested.is_same_typed(nested),
			"post-hook normalization preserves outer container types"
		)
		suite.check(
			properties.hook_non_finite == {"nan": null, "inf": null, "negative": null},
			"hook typed float dictionary normalized"
		)
	suite.check(
		tags == ["original"] and ratings.score == 1.5,
		"callback changes do not mutate caller's typed containers"
	)
	suite.check(
		is_nan(items[0].number) and nested.items[0] == INF,
		"callback changes do not mutate caller's nested containers"
	)
	suite.check(
		is_nan(non_finite.nan) and non_finite.inf == INF and non_finite.negative == -INF,
		"normalization does not mutate caller's typed float dictionary"
	)
	await suite.dispose(node)
