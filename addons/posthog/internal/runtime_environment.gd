extends RefCounted


static func detect(
	editor_hint: bool = Engine.is_editor_hint(),
	editor_build: bool = OS.has_feature("editor"),
	dedicated_server: bool = OS.has_feature("dedicated_server"),
	debug_build: bool = OS.is_debug_build()
) -> String:
	if editor_hint:
		return "editor"
	if editor_build:
		return "editor_play"
	if dedicated_server:
		return "dedicated_server"
	return "export_debug" if debug_build else "export_release"
