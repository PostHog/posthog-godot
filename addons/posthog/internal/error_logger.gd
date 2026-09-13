extends Logger

var debounce_ms: int = 1000
var _mutex := Mutex.new()
var _pending: Array = []
var _last_capture: int = -1
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
	var now := Time.get_ticks_msec()
	if (
		not _enabled
		or _pending.size() >= 20
		or (_last_capture >= 0 and now - _last_capture < debounce_ms)
	):
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
	_pending.append(
		{
			"message": rationale if not rationale.is_empty() else code,
			"type": "GDScriptError" if error_type == ERROR_TYPE_SCRIPT else "GodotError",
			"frames": frames
		}
	)
	_last_capture = now
	_mutex.unlock()


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
