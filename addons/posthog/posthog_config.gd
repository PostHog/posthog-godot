class_name PostHogConfig
extends Resource

## Configuration for a PostHog client. Use a project API key, never a personal API key.
enum PersonProfiles { ALWAYS, IDENTIFIED_ONLY, NEVER }

@export var api_key: String = ""
@export var host: String = "https://us.i.posthog.com"
@export_range(1, 10000) var flush_at: int = 20
@export_range(1, 3600) var flush_interval_seconds: float = 30.0
@export_range(1, 100000) var max_queue_size: int = 1000
@export_range(1, 1000) var max_batch_size: int = 50
@export var person_profiles: PersonProfiles = PersonProfiles.IDENTIFIED_ONLY
@export var reuse_anonymous_id: bool = false
@export var preload_feature_flags: bool = true
@export_range(0, 5) var feature_flag_request_max_retries: int = 1
@export var send_feature_flag_event: bool = true
@export var send_default_person_properties_for_flags: bool = true
@export var capture_application_lifecycle_events: bool = true
@export var capture_exceptions: bool = true
@export var capture_exceptions_in_editor: bool = true
@export_range(0, 60000) var exception_debounce_interval_ms: int = 1000
@export var flush_on_quit: bool = true
@export_range(0.1, 30) var flush_on_quit_timeout_seconds: float = 3.0
@export_range(0.1, 120) var request_timeout_seconds: float = 10.0
@export var opt_out_by_default: bool = false
@export var persistence: bool = true
@export var storage_path: String = "user://posthog"
@export var app_version: String = ""
@export var app_build: String = ""
## Return the event Dictionary to send it, or null to drop it. Runs on the main thread.
var before_send: Callable


func validation_error() -> String:
	if api_key.strip_edges().is_empty():
		return "api_key is required"
	if not host.begins_with("https://") and not host.begins_with("http://"):
		return "host must be an HTTP(S) URL"
	if host.contains("?") or host.contains("#") or host.contains("@"):
		return "host must not contain query parameters, fragments, or credentials"
	if host.trim_prefix("https://").trim_prefix("http://").split("/")[0].is_empty():
		return "host must include a hostname"
	if flush_at < 1 or max_queue_size < 1 or max_batch_size < 1:
		return "queue and batch limits must be positive"
	if not is_finite(flush_interval_seconds) or flush_interval_seconds < 1:
		return "flush_interval_seconds must be at least 1"
	if not is_finite(request_timeout_seconds) or request_timeout_seconds <= 0:
		return "request_timeout_seconds must be positive"
	if not is_finite(flush_on_quit_timeout_seconds) or flush_on_quit_timeout_seconds <= 0:
		return "flush_on_quit_timeout_seconds must be positive"
	if feature_flag_request_max_retries < 0 or feature_flag_request_max_retries > 5:
		return "feature_flag_request_max_retries must be between 0 and 5"
	if exception_debounce_interval_ms < 0:
		return "exception_debounce_interval_ms must not be negative"
	if person_profiles < PersonProfiles.ALWAYS or person_profiles > PersonProfiles.NEVER:
		return "invalid person_profiles mode"
	if persistence and not storage_path.begins_with("user://"):
		return "storage_path must be under user://"
	return ""
