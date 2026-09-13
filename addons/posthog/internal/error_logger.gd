extends Logger

const MAX_EVENTS_PER_FRAME = 5
const MAX_EVENTS_PER_WINDOW = 20
const RATE_WINDOW_MS = 10000
const MAX_PENDING_ERRORS = 20
const MAX_ERROR_KEYS = 128

var debounce_ms: int = 1000
var _mutex := Mutex.new()
var _pending: Array = []
var _last_seen: Dictionary = {}
var _event_times: Array[int] = []
var _last_frame: int = -1
var _frame_events: int = 0
var _enabled: bool = true


func _log_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	script_backtraces: Array[ScriptBacktrace]
) -> void:
	if error_type == ERROR_TYPE_WARNING or file.contains("addons/posthog/"):
		return
	_mutex.lock()
	if not _enabled or _pending.size() >= MAX_PENDING_ERRORS:
		_mutex.unlock()
		return
	var frames: Array = []
	for backtrace in script_backtraces:
		for index in range(mini(backtrace.get_frame_count(), 50)):
			var filename := backtrace.get_frame_file(index)
			if filename.contains("addons/posthog/"):
				_mutex.unlock()
				return
			frames.append(
				{
					"source": filename,
					"function": backtrace.get_frame_function(index),
					"line": backtrace.get_frame_line(index)
				}
			)
		if not frames.is_empty():
			break
	if frames.is_empty():
		frames.append({"source": file, "function": function, "line": line})
	var message := rationale if not rationale.is_empty() else code
	var key := JSON.stringify([error_type, file, line, message]).sha256_text()
	if not _accept_error(key, _now_ms(), _frame_number()):
		_mutex.unlock()
		return
	_pending.append(
		{
			"message": message,
			"type": "GDScriptError" if error_type == ERROR_TYPE_SCRIPT else "GodotError",
			"frames": frames
		}
	)
	_mutex.unlock()


func _accept_error(key: String, now: int, frame: int) -> bool:
	if frame != _last_frame:
		_last_frame = frame
		_frame_events = 0
	while not _event_times.is_empty() and now - _event_times[0] >= RATE_WINDOW_MS:
		_event_times.pop_front()
	for previous_key in _last_seen.keys():
		if now - _last_seen[previous_key] >= debounce_ms:
			_last_seen.erase(previous_key)
	if (
		_frame_events >= MAX_EVENTS_PER_FRAME
		or _event_times.size() >= MAX_EVENTS_PER_WINDOW
		or _last_seen.has(key)
	):
		return false
	_frame_events += 1
	_event_times.append(now)
	if debounce_ms > 0:
		if _last_seen.size() >= MAX_ERROR_KEYS:
			_last_seen.erase(_last_seen.keys()[0])
		_last_seen[key] = now
	return true


func _now_ms() -> int:
	return Time.get_ticks_msec()


func _frame_number() -> int:
	return Engine.get_process_frames()


func drain() -> Array:
	_mutex.lock()
	var result := _pending
	_pending = []
	_mutex.unlock()
	return result


func disable() -> void:
	_mutex.lock()
	_enabled = false
	_pending.clear()
	_mutex.unlock()
