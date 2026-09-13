extends Node

signal flush_finished(success: bool)
signal events_dropped(count: int, reason: String)

const Utils = preload("utils.gd")
var config: PostHogConfig
var storage: RefCounted
var transport: Node
var events: Array = []
var running: bool = true
var flushing: bool = false
var _batch_size: int
var _request: HTTPRequest
var _generation: int = 0
var _retry_count: int = 0
var _retry_at: int = 0
var _next_flush: int = 0


func initialize() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_batch_size = config.max_batch_size
	events = storage.load_events(config.max_queue_size)
	_next_flush = Time.get_ticks_msec() + int(config.flush_interval_seconds * 1000)


func enqueue(event: Dictionary) -> void:
	if not running:
		return
	while events.size() >= config.max_queue_size:
		storage.delete_event(events.pop_front().uuid)
		events_dropped.emit(1, "queue_full")
		if not running:
			return
	events.append(event)
	storage.save_event(event)
	if events.size() >= mini(config.flush_at, config.max_queue_size):
		flush.call_deferred()


func flush() -> bool:
	if not running:
		return false
	if flushing:
		return await flush_finished
	if events.is_empty():
		return true
	if Time.get_ticks_msec() < _retry_at:
		return false
	flushing = true
	_send_next.call_deferred(_generation)
	return await flush_finished


func stop() -> void:
	running = false
	_generation += 1
	transport.cancel(_request)
	_request = null
	if flushing:
		_finish(false)


func clear() -> void:
	stop()
	for event in events:
		storage.delete_event(event.uuid)
	events.clear()
	_retry_at = 0
	_retry_count = 0


func _process(_delta: float) -> void:
	if not running or flushing or events.is_empty():
		return
	var now := Time.get_ticks_msec()
	if (_retry_at > 0 and now >= _retry_at) or now >= _next_flush:
		_next_flush = now + int(config.flush_interval_seconds * 1000)
		flush()


func _send_next(generation: int) -> void:
	if generation != _generation or not running:
		return
	if events.is_empty():
		_finish(true)
		return
	var batch := events.slice(0, _batch_size)
	_request = transport.post(
		"/batch/",
		{"api_key": config.api_key, "batch": batch, "sent_at": Utils.timestamp()},
		func(result: int, status: int, headers: PackedStringArray, _body: String):
			if generation != _generation:
				return
			_request = null
			if result == HTTPRequest.RESULT_SUCCESS and status >= 200 and status < 300:
				_remove_batch(batch)
				_retry_count = 0
				_retry_at = 0
				_send_next.call_deferred(generation)
			elif status == 413:
				if batch.size() == 1:
					_remove_batch(batch)
					events_dropped.emit(1, "event_too_large")
				else:
					_batch_size = maxi(1, int(batch.size() / 2.0))
				_send_next.call_deferred(generation)
			elif status >= 400 and status < 500 and status != 408 and status != 429:
				_remove_batch(batch)
				events_dropped.emit(batch.size(), "http_%d" % status)
				_finish(false)
			else:
				_retry_count += 1
				var delay := minf(30.0, 5.0 * pow(2.0, mini(_retry_count - 1, 4)))
				for header in headers:
					if header.to_lower().begins_with("retry-after:"):
						var seconds := header.substr(header.find(":") + 1).strip_edges()
						if seconds.is_valid_float():
							delay = maxf(delay, clampf(seconds.to_float(), 0, 86400))
				_retry_at = Time.get_ticks_msec() + int(delay * 1000)
				_finish(false)
	)


func _remove_batch(batch: Array) -> void:
	# Captures can evict in-flight events. Acknowledgements must remove IDs, not queue positions.
	var ids: Dictionary = {}
	for event in batch:
		ids[event.uuid] = true
		storage.delete_event(event.uuid)
	events = events.filter(func(event: Dictionary): return not ids.has(event.uuid))


func _finish(success: bool) -> void:
	flushing = false
	_next_flush = Time.get_ticks_msec() + int(config.flush_interval_seconds * 1000)
	flush_finished.emit(success)
