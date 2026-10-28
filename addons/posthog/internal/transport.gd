extends Node

const Utils = preload("utils.gd")

var config: PostHogConfig
var _requests: Array[HTTPRequest] = []


func post(path: String, body: Dictionary, callback: Callable) -> HTTPRequest:
	var request := HTTPRequest.new()
	request.timeout = config.request_timeout_seconds
	request.body_size_limit = 5 * 1024 * 1024
	request.max_redirects = 0
	add_child(request)
	_requests.append(request)
	request.request_completed.connect(
		func(result: int, status: int, headers: PackedStringArray, data: PackedByteArray):
			if not _requests.has(request):
				return
			_requests.erase(request)
			request.queue_free()
			callback.call(result, status, headers, data.get_string_from_utf8())
	)
	var headers := PackedStringArray(
		[
			"Content-Type: application/json",
			"Accept: application/json",
			"User-Agent: " + Utils.LIBRARY + "/" + Utils.VERSION,
		]
	)
	var error := request.request(
		config.host.trim_suffix("/") + path, headers, HTTPClient.METHOD_POST, JSON.stringify(body)
	)
	if error != OK:
		_fail_start.call_deferred(request, callback)
	return request


func cancel(request: HTTPRequest) -> void:
	if is_instance_valid(request) and _requests.has(request):
		_requests.erase(request)
		request.cancel_request()
		request.queue_free()


func _fail_start(request: HTTPRequest, callback: Callable) -> void:
	if not _requests.has(request):
		return
	cancel(request)
	callback.call(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), "")


func _exit_tree() -> void:
	for request in _requests.duplicate():
		cancel(request)
