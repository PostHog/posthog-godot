extends Node

var calls: Array = []
var responses: Array = []
var pending: Array = []
var hold: bool = false


func post(path: String, body: Dictionary, callback: Callable) -> HTTPRequest:
	var request := HTTPRequest.new()
	add_child(request)
	calls.append({"path": path, "body": body.duplicate(true)})
	pending.append({"request": request, "callback": callback})
	if not hold:
		complete_next.call_deferred()
	return request


func cancel(request: HTTPRequest) -> void:
	for item in pending.duplicate():
		if item.request == request:
			pending.erase(item)
			item.request.queue_free()


func complete_next() -> void:
	if pending.is_empty():
		return
	var item: Dictionary = pending.pop_front()
	var response: Dictionary = (
		responses.pop_front() if not responses.is_empty() else {"status": 200}
	)
	item.request.queue_free()
	item.callback.call(
		response.get("result", HTTPRequest.RESULT_SUCCESS),
		response.get("status", 200),
		PackedStringArray(response.get("headers", [])),
		response.get("body", "{}")
	)
