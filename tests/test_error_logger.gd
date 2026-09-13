extends RefCounted


class ControlledLogger:
	extends "res://addons/posthog/internal/error_logger.gd"

	var now: int = 0
	var frame: int = 0

	func _now_ms() -> int:
		return now

	func _frame_number() -> int:
		return frame


class RecursiveLogger:
	extends ControlledLogger

	var extraction_calls: int = 0

	func _extract_frames(
		backtraces: Array[ScriptBacktrace],
		file: String,
		function: String,
		line: int,
		error_type: int
	) -> Array:
		extraction_calls += 1
		if extraction_calls < 3:
			_log_error(
				"nested", "res://game.gd", 99, "recursive error", "", false, ERROR_TYPE_SCRIPT, []
			)
		return super._extract_frames(backtraces, file, function, line, error_type)


static func run(check: Callable) -> void:
	var logger := ControlledLogger.new()
	_log(logger, "save failed")
	_log(logger, "load failed")
	check.call(logger.drain().size() == 2, "distinct errors within debounce interval retained")
	_log(logger, "save failed")
	check.call(logger.drain().is_empty(), "identical error deduplicated across drains")
	_log(logger, "save failed", "res://other.gd")
	_log(logger, "save failed", "res://game.gd", 11)
	check.call(logger.drain().size() == 2, "error fingerprint distinguishes file and line")
	logger.now = 1000
	logger.frame += 1
	_log(logger, "save failed")
	check.call(logger.drain().size() == 1, "identical error allowed at debounce boundary")

	logger = ControlledLogger.new()
	logger.debounce_ms = 0
	for index in 10:
		_log(logger, "repeated")
	check.call(logger.drain().size() == 5, "disabling deduplication retains per-frame protection")
	_log(logger, "new after drain")
	check.call(logger.drain().is_empty(), "draining does not bypass frame limit")
	logger.frame += 1
	_log(logger, "next frame")
	check.call(logger.drain().size() == 1, "per-frame limit resets on next frame")

	logger = ControlledLogger.new()
	logger.debounce_ms = 0
	for frame in 4:
		logger.frame = frame
		for index in 5:
			_log(logger, "burst")
		check.call(logger.drain().size() == 5, "sliding window permits bounded burst")
	logger.frame += 1
	logger.now = 9999
	_log(logger, "window full")
	check.call(logger.drain().is_empty(), "sliding window caps cross-frame error volume")
	logger.now = 10000
	_log(logger, "window recovered")
	check.call(logger.drain().size() == 1, "sliding window recovers at expiry boundary")

	logger = ControlledLogger.new()
	for index in 30:
		logger.frame += 1
		logger.now += 10001
		_log(logger, "pending-%d" % index)
	check.call(logger.drain().size() == 20, "undrained automatic errors remain bounded")
	logger.disable()
	_log(logger, "disabled")
	check.call(logger.drain().is_empty(), "disabled logger does not accept errors")
	_test_backtraces(check)
	_test_recursion_and_threads(check)


static func _test_recursion_and_threads(check: Callable) -> void:
	var recursive := RecursiveLogger.new()
	_log(recursive, "outer error")
	check.call(
		recursive.extraction_calls == 1 and recursive.drain().size() == 1,
		"recursive logger callbacks are blocked"
	)
	check.call(
		recursive._blocked_threads.is_empty(), "logger recursion guard released after capture"
	)

	var logger := ControlledLogger.new()
	logger.begin_forwarding()
	logger.begin_forwarding()
	logger.end_forwarding()
	_log(logger, "main-thread feedback")
	check.call(logger.drain().is_empty(), "nested forwarding suppression remains active")
	var worker := Thread.new()
	check.call(worker.start(func(): _log(logger, "worker error")) == OK, "error worker starts")
	worker.wait_to_finish()
	var errors := logger.drain()
	check.call(
		errors.size() == 1 and errors[0].message == "worker error",
		"forwarding does not suppress unrelated worker-thread errors"
	)
	logger.end_forwarding()
	_log(logger, "main-thread recovered")
	check.call(
		logger.drain().size() == 1 and logger._blocked_threads.is_empty(),
		"forwarding suppression ends cleanly"
	)


static func _test_backtraces(check: Callable) -> void:
	var shallow := _shallow_trace()
	var deep := _deep_trace()
	var logger := ControlledLogger.new()
	logger._log_error(
		"test",
		shallow.get_frame_file(0),
		shallow.get_frame_line(0),
		"matching",
		"",
		false,
		Logger.ERROR_TYPE_SCRIPT,
		[deep, shallow]
	)
	var errors := logger.drain()
	check.call(
		errors.size() == 1 and errors[0].frames[0].line == shallow.get_frame_line(0),
		"matching error location wins over longer backtrace"
	)

	logger = ControlledLogger.new()
	logger._log_error(
		"test",
		"res://unmatched.gd",
		999,
		"longest",
		"",
		false,
		Logger.ERROR_TYPE_SCRIPT,
		[shallow, deep]
	)
	errors = logger.drain()
	check.call(
		errors.size() == 1 and errors[0].frames.size() == deep.get_frame_count(),
		"unmatched error uses longest available backtrace"
	)

	logger = ControlledLogger.new()
	logger._log_error(
		"native_function",
		"core/object.cpp",
		42,
		"native",
		"",
		false,
		Logger.ERROR_TYPE_ERROR,
		[shallow]
	)
	errors = logger.drain()
	check.call(
		errors.size() == 1 and errors[0].frames[0].source == "core/object.cpp",
		"native origin retained as most recent frame"
	)
	check.call(
		errors.size() == 1 and errors[0].frames.size() == shallow.get_frame_count() + 1,
		"native origin supplements rather than replaces script frames"
	)

	logger = ControlledLogger.new()
	logger._log_error(
		"internal",
		"res://addons/posthog/internal/transport.gd",
		10,
		"sdk failure",
		"",
		false,
		Logger.ERROR_TYPE_SCRIPT,
		[shallow]
	)
	check.call(logger.drain().is_empty(), "SDK-originated failures are ignored")
	logger._log_error(
		"game",
		"res://myaddons/posthog/game.gd",
		10,
		"game failure",
		"",
		false,
		Logger.ERROR_TYPE_SCRIPT,
		[shallow]
	)
	check.call(logger.drain().size() == 1, "similarly named game paths are not excluded")

	logger = ControlledLogger.new()
	logger._log_error(
		"native",
		"core/object.cpp",
		42,
		"deep native error",
		"",
		false,
		Logger.ERROR_TYPE_ERROR,
		[_long_trace(60)]
	)
	errors = logger.drain()
	check.call(
		(
			errors.size() == 1
			and errors[0].frames.size() == 50
			and errors[0].frames[0].source == "core/object.cpp"
		),
		"frame limit reserves space for native origin"
	)

	var script := GDScript.new()
	script.resource_path = "res://addons/posthog/_test_trace.gd"
	script.source_code = (
		"extends RefCounted\nfunc trace() -> ScriptBacktrace:\n"
		+ "\treturn Engine.capture_script_backtraces(false)[0]\n"
	)
	check.call(script.reload() == OK, "SDK-origin trace fixture compiles")
	var fixture: RefCounted = script.new()
	var sdk_trace: ScriptBacktrace = fixture.trace()
	logger = ControlledLogger.new()
	logger._log_error(
		"native",
		"core/object.cpp",
		42,
		"SDK engine failure",
		"",
		false,
		Logger.ERROR_TYPE_ERROR,
		[sdk_trace]
	)
	check.call(logger.drain().is_empty(), "native errors invoked directly by SDK code are ignored")


static func _long_trace(depth: int) -> ScriptBacktrace:
	if depth > 0:
		return _long_trace(depth - 1)
	return Engine.capture_script_backtraces(false)[0]


static func _shallow_trace() -> ScriptBacktrace:
	return Engine.capture_script_backtraces(false)[0]


static func _deep_trace() -> ScriptBacktrace:
	return _capture_deep_trace()


static func _capture_deep_trace() -> ScriptBacktrace:
	return Engine.capture_script_backtraces(false)[0]


static func _log(
	logger: Logger, message: String, file: String = "res://game.gd", line: int = 10
) -> void:
	logger._log_error("test", file, line, message, "", false, Logger.ERROR_TYPE_SCRIPT, [])
