extends RefCounted

const Utils = preload("utils.gd")
const TIMEOUT_MS = 30 * 60 * 1000
const MAX_LENGTH_MS = 24 * 60 * 60 * 1000
var id: String = ""
var started_at: int = 0
var last_activity: int = 0
var foreground: bool = true


func get_id(now: int = Time.get_ticks_msec()) -> String:
	if not id.is_empty() and (now - last_activity > TIMEOUT_MS or now - started_at > MAX_LENGTH_MS):
		id = ""
	if id.is_empty() and foreground:
		id = Utils.uuid_v7()
		started_at = now
		last_activity = now
	return id


func touch(now: int = Time.get_ticks_msec()) -> void:
	if not get_id(now).is_empty():
		last_activity = now


func set_foreground(value: bool, now: int = Time.get_ticks_msec()) -> void:
	foreground = value
	if value:
		touch(now)
	elif not id.is_empty():
		last_activity = now


func reset() -> void:
	id = ""
