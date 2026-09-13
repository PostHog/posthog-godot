extends Logger

const MAX_EVENTS_PER_FRAME = 5
const MAX_EVENTS_PER_WINDOW = 20
const RATE_WINDOW_MS = 10000
const MAX_PENDING_ERRORS = 20
const MAX_ERROR_KEYS = 128
const MAX_STACK_FRAMES = 50

var debounce_ms: int = 1000
var _mutex := Mutex.new()
var _pending: Array = []
var _last_seen: Dictionary = {}
var _event_times: Array[int] = []
var _last_frame: int = -1
var _frame_events: int = 0
var _enabled: bool = true
var _blocked_threads: Dictionary = {}


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
	if error_type == ERROR_TYPE_WARNING or _is_sdk_file(file):
		return
	var thread_id := OS.get_thread_caller_id()
	_mutex.lock()
	if not _enabled or _pending.size() >= MAX_PENDING_ERRORS or _blocked_threads.has(thread_id):
		_mutex.unlock()
		return
	_blocked_threads[thread_id] = 1
	_record_error(function, file, line, code, rationale, error_type, script_backtraces)
	_blocked_threads.erase(thread_id)
	_mutex.unlock()


func _record_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	error_type: int,
	script_backtraces: Array[ScriptBacktrace]
) -> void:
	var frames := _extract_frames(script_backtraces, file, function, line, error_type)
	if frames.is_empty():
		return
	var message := rationale if not rationale.is_empty() else code
	var key := JSON.stringify([error_type, file, line, message]).sha256_text()
	if not _accept_error(key, _now_ms(), _frame_number()):
		return
	_pending.append(
		{
			"message": message,
			"type": "GDScriptError" if error_type == ERROR_TYPE_SCRIPT else "GodotError",
			"frames": frames
		}
	)


func _extract_frames(
	backtraces: Array[ScriptBacktrace], file: String, function: String, line: int, error_type: int
) -> Array:
	var selected := _select_backtrace(backtraces, file, line)
	if selected != null and _is_sdk_file(selected.get_frame_file(0)):
		return []
	var frames: Array = []
	var origin := {"source": file, "function": function, "line": line}
	if error_type == ERROR_TYPE_ERROR:
		frames.append(origin)
	if selected != null:
		for index in range(mini(selected.get_frame_count(), MAX_STACK_FRAMES - frames.size())):
			frames.append(
				{
					"source": selected.get_frame_file(index),
					"function": selected.get_frame_function(index),
					"line": selected.get_frame_line(index)
				}
			)
	if frames.is_empty():
		frames.append(origin)
	return frames


func _select_backtrace(
	backtraces: Array[ScriptBacktrace], file: String, line: int
) -> ScriptBacktrace:
	var selected: ScriptBacktrace
	for backtrace in backtraces:
		if backtrace == null or backtrace.get_frame_count() == 0:
			continue
		if backtrace.get_frame_file(0) == file and backtrace.get_frame_line(0) == line:
			return backtrace
		if selected == null or backtrace.get_frame_count() > selected.get_frame_count():
			selected = backtrace
	return selected


func _is_sdk_file(file: String) -> bool:
	return file.begins_with("res://addons/posthog/")


func begin_forwarding() -> void:
	_mutex.lock()
	var thread_id := OS.get_thread_caller_id()
	_blocked_threads[thread_id] = _blocked_threads.get(thread_id, 0) + 1
	_mutex.unlock()


func end_forwarding() -> void:
	_mutex.lock()
	var thread_id := OS.get_thread_caller_id()
	var depth: int = _blocked_threads.get(thread_id, 0)
	if depth <= 1:
		_blocked_threads.erase(thread_id)
	else:
		_blocked_threads[thread_id] = depth - 1
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


func disable() -> Array:
	_mutex.lock()
	_enabled = false
	var result := _pending
	_pending = []
	_mutex.unlock()
	return result
