extends RefCounted


class ControlledLogger:
	extends "res://addons/posthog/internal/error_logger.gd"

	var now: int = 0
	var frame: int = 0

	func _now_ms() -> int:
		return now

	func _frame_number() -> int:
		return frame


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


static func _log(
	logger: Logger, message: String, file: String = "res://game.gd", line: int = 10
) -> void:
	logger._log_error("test", file, line, message, "", false, Logger.ERROR_TYPE_SCRIPT, [])
